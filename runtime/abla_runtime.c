#include "abla_runtime.h"

int8_t ablaCompilerTypeNeedsNormalization(
    const char* type,
    int64_t length
) {
    if (type == NULL || length <= 0) return 0;
    const unsigned char first = (unsigned char)type[0];
    const unsigned char last = (unsigned char)type[length - 1];
    if (first == ' ' || last == ' ' || last == '?' ||
        first == 'F' || first == '(') return 1;
    if (length == 3 && first == 'i' && type[1] == 'n' && type[2] == 't') {
        return 1;
    }
    if (length >= 6 && first == 'a' &&
        type[1] == 'r' && type[2] == 'r' && type[3] == 'a' &&
        type[4] == 'y' && type[5] == '<') return 1;
    if (length >= 7 && first == 'S' &&
        type[1] == 'h' && type[2] == 'a' && type[3] == 'r' &&
        type[4] == 'e' && type[5] == 'd' && type[6] == '<') return 1;
    if (length >= 5 && first == 'W' &&
        type[1] == 'e' && type[2] == 'a' && type[3] == 'k' &&
        type[4] == '<') return 1;
    if (length >= 6 && first == 'M' &&
        type[1] == 'u' && type[2] == 't' && type[3] == 'e' &&
        type[4] == 'x' && type[5] == '<') return 1;
    if (length >= 5 && first == 'C' &&
        type[1] == 'e' && type[2] == 'l' && type[3] == 'l' &&
        type[4] == '<') return 1;
    if (length >= 10 && first == 'G' &&
        type[1] == 'e' && type[2] == 'n' && type[3] == 'e' &&
        type[4] == 'r' && type[5] == 'a' && type[6] == 't' &&
        type[7] == 'o' && type[8] == 'r' && type[9] == '<') return 1;
    if (length >= 5 && first == 'T' &&
        type[1] == 'a' && type[2] == 's' && type[3] == 'k' &&
        type[4] == '<') return 1;
    if (length >= 7 && first == 'T' &&
        type[1] == 'h' && type[2] == 'r' && type[3] == 'e' &&
        type[4] == 'a' && type[5] == 'd' && type[6] == '<') return 1;
    if (length >= 7 && first == 'B' &&
        type[1] == 'o' && type[2] == 'r' && type[3] == 'r' &&
        type[4] == 'o' && type[5] == 'w' && type[6] == '<') return 1;
    if (length >= 7 && first == 'b' &&
        type[1] == 'o' && type[2] == 'r' && type[3] == 'r' &&
        type[4] == 'o' && type[5] == 'w' && type[6] == '(') return 1;
    return 0;
}

#include <stdatomic.h>

typedef struct AblaField {
    uint32_t symbol;
    AblaValue value;
} AblaField;

struct AblaArray {
    size_t length;
    size_t capacity;
    AblaValue* values;
};

struct AblaObject {
    uint32_t type_symbol;
    size_t count;
    size_t capacity;
    AblaField* fields;
};

struct AblaStringRope {
    AblaString left;
    AblaString right;
    char* flattened;
};

static _Noreturn void panic(const char* message, uint64_t length) {
    abla_platform_panic(message, length);
}

static void copy_bytes(char* destination, const char* source, size_t count) {
    for (size_t index = 0; index < count; ++index) destination[index] = source[index];
}

static bool equal_bytes(const char* left, const char* right, size_t count) {
    size_t index = 0;
    while (index < count && left[index] == right[index]) ++index;
    return index == count;
}

static const char* string_data(AblaString value) {
    if (value.data != (const char*)0) return value.data;
    if (value.rope == (AblaStringRope*)0) {
        panic("invalid string storage", 22);
    }
    if (value.rope->flattened != (char*)0) return value.rope->flattened;

    size_t capacity = 64;
    size_t count = 1;
    AblaString* pending =
        (AblaString*)abla_platform_alloc(sizeof(AblaString) * capacity);
    abla_platform_memory_set_layout(pending, 9);
    pending[0] = value;

    if (value.length == SIZE_MAX) {
        abla_platform_free(pending);
        panic("string length overflow", 22);
    }
    char* flattened = (char*)abla_platform_alloc(value.length + 1);
    size_t output = 0;
    while (count != 0) {
        const AblaString current = pending[--count];
        const char* current_data = current.data;
        if (current_data == (const char*)0 &&
            current.rope != (AblaStringRope*)0) {
            current_data = current.rope->flattened;
        }
        if (current_data != (const char*)0) {
            if (output > value.length ||
                current.length > value.length - output) {
                abla_platform_free(pending);
                abla_platform_free(flattened);
                panic("invalid string rope", 19);
            }
            copy_bytes(flattened + output, current_data, current.length);
            output += current.length;
            continue;
        }
        if (current.rope == (AblaStringRope*)0) {
            abla_platform_free(pending);
            abla_platform_free(flattened);
            panic("invalid string rope", 19);
        }
        if (count > SIZE_MAX - 2) {
            abla_platform_free(pending);
            abla_platform_free(flattened);
            panic("string rope is too deep", 23);
        }
        if (count + 2 > capacity) {
            if (capacity > SIZE_MAX / 2 ||
                capacity * 2 > SIZE_MAX / sizeof(AblaString)) {
                abla_platform_free(pending);
                abla_platform_free(flattened);
                panic("string rope is too deep", 23);
            }
            const size_t next_capacity = capacity * 2;
            AblaString* next = (AblaString*)abla_platform_alloc(
                sizeof(AblaString) * next_capacity);
            abla_platform_memory_set_layout(next, 9);
            for (size_t index = 0; index < count; ++index) {
                next[index] = pending[index];
            }
            abla_platform_free(pending);
            pending = next;
            capacity = next_capacity;
        }
        pending[count++] = current.rope->right;
        pending[count++] = current.rope->left;
    }
    abla_platform_free(pending);
    if (output != value.length) {
        abla_platform_free(flattened);
        panic("invalid string rope", 19);
    }
    flattened[value.length] = '\0';
    value.rope->flattened = flattened;
    abla_platform_memory_set_cache_owner(flattened, value.rope);
    return flattened;
}

static bool string_equal(AblaString left, AblaString right) {
    if (left.length != right.length) return false;
    const char* left_data = string_data(left);
    const char* right_data = string_data(right);
    for (size_t index = 0; index < left.length; ++index) {
        if (left_data[index] != right_data[index]) return false;
    }
    return true;
}

AblaValue abla_void(void) { return (AblaValue){.tag = ABLA_VOID}; }
AblaValue abla_null(void) { return (AblaValue){.tag = ABLA_NULL}; }
AblaValue abla_i64(int64_t value) {
    return (AblaValue){.tag = ABLA_I64, .as.i64 = value};
}
AblaValue abla_bool(bool value) {
    return (AblaValue){.tag = ABLA_BOOL, .as.boolean = value};
}
AblaValue abla_string_static(const char* data, size_t length) {
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = data,
            .length = length,
            .owner = (const char*)0,
            .rope = (AblaStringRope*)0}};
}
AblaValue abla_function(uint32_t function) {
    return (AblaValue){
        .tag = ABLA_FUNCTION,
        .as.function = {
            .id = function,
            .capture_count = 0,
            .captures = (AblaValue*)0}};
}
AblaValue abla_closure(
    uint32_t function,
    const AblaValue* captures,
    uint64_t capture_count) {
    AblaValue* owned_captures = capture_count == 0
        ? (AblaValue*)0
        : (AblaValue*)abla_platform_alloc(sizeof(AblaValue) * capture_count);
    if (owned_captures != (AblaValue*)0) {
        abla_platform_memory_set_layout(owned_captures, 2);
    }
    for (size_t index = 0; index < capture_count; ++index) {
        owned_captures[index] = captures[index];
    }
    return (AblaValue){
        .tag = ABLA_FUNCTION,
        .as.function = {
            .id = function,
            .capture_count = capture_count,
            .captures = owned_captures}};
}

int64_t abla_as_i64(AblaValue value) {
    if (value.tag != ABLA_I64) panic("expected i64", 12);
    return value.as.i64;
}
bool abla_as_bool(AblaValue value) {
    if (value.tag != ABLA_BOOL) panic("expected bool", 13);
    return value.as.boolean;
}
const char* abla_as_cstring(AblaValue value) {
    if (value.tag != ABLA_STRING) panic("expected string", 15);
    const char* data = string_data(value.as.string);
    if (data[value.as.string.length] == '\0') return data;
    char* terminated = (char*)abla_platform_alloc(value.as.string.length + 1);
    copy_bytes(terminated, data, value.as.string.length);
    terminated[value.as.string.length] = '\0';
    return terminated;
}
const char* abla_string_data(AblaValue value) {
    if (value.tag != ABLA_STRING) panic("expected string", 15);
    return string_data(value.as.string);
}
uint32_t abla_as_function(AblaValue value) {
    if (value.tag != ABLA_FUNCTION) panic("expected function", 17);
    return value.as.function.id;
}
uint64_t abla_function_capture_count(AblaValue value) {
    if (value.tag != ABLA_FUNCTION) panic("expected function", 17);
    return value.as.function.capture_count;
}

AblaValue* abla_function_capture_pointer(AblaValue value) {
    (void)abla_as_function(value);
    return value.as.function.captures;
}

void abla_closure_release(AblaValue value) {
    abla_platform_free(abla_function_capture_pointer(value));
}

typedef struct AblaOwnedBytes {
    uint64_t length;
    uint8_t data[];
} AblaOwnedBytes;

void* abla_owned_bytes_from_value(AblaValue value) {
    const char* data = abla_string_data(value);
    const uint64_t length = (uint64_t)value.as.string.length;
    if (length > SIZE_MAX - sizeof(AblaOwnedBytes)) {
        panic("string length overflow", 22);
    }
    AblaOwnedBytes* handle = (AblaOwnedBytes*)abla_platform_alloc(
        sizeof(AblaOwnedBytes) + (size_t)length);
    if (handle == NULL) panic("out of memory", 13);
    handle->length = length;
    if (length != 0) copy_bytes((char*)handle->data, data, (size_t)length);
    return handle;
}

const uint8_t* abla_owned_bytes_data(void* opaque_handle) {
    return ((const AblaOwnedBytes*)opaque_handle)->data;
}

uint64_t abla_owned_bytes_length(void* opaque_handle) {
    return ((const AblaOwnedBytes*)opaque_handle)->length;
}

void abla_owned_bytes_release(void* handle) {
    abla_platform_free(handle);
}
AblaValue abla_function_capture(AblaValue value, uint64_t index) {
    if (value.tag != ABLA_FUNCTION) panic("expected function", 17);
    if (index >= value.as.function.capture_count) {
        panic("function capture out of bounds", 30);
    }
    return value.as.function.captures[index];
}
AblaValue abla_cell_create(AblaValue value) {
    AblaValue* cell = (AblaValue*)abla_platform_alloc(sizeof(AblaValue));
    abla_platform_memory_set_layout(cell, 8);
    *cell = value;
    return (AblaValue){.tag = ABLA_CELL, .as.cell = cell};
}
AblaValue abla_cell_get(AblaValue cell) {
    if (cell.tag != ABLA_CELL) panic("expected capture cell", 21);
    return *cell.as.cell;
}
AblaValue abla_cell_set(AblaValue cell, AblaValue value) {
    if (cell.tag != ABLA_CELL) panic("expected capture cell", 21);
    *cell.as.cell = value;
    return value;
}

struct AblaSharedControl {
    _Atomic size_t strong;
    _Atomic size_t weak;
    AblaValue value;
    _Atomic size_t lock;
};

static AblaSharedControl* shared_control(AblaValue value) {
    if (value.tag != ABLA_SHARED) panic("expected Shared value", 21);
    return value.as.shared;
}

static AblaSharedControl* weak_control(AblaValue value) {
    if (value.tag != ABLA_WEAK) panic("expected Weak value", 19);
    return value.as.weak;
}

AblaValue abla_shared_create(AblaValue value) {
    AblaSharedControl* control =
        (AblaSharedControl*)abla_platform_alloc(sizeof(AblaSharedControl));
    abla_platform_memory_set_layout(control, 7);
    atomic_init(&control->strong, 1);
    /* One implicit weak count keeps the control block alive while strong. */
    atomic_init(&control->weak, 1);
    control->value = value;
    atomic_init(&control->lock, 0);
    return (AblaValue){.tag = ABLA_SHARED, .as.shared = control};
}

AblaValue abla_shared_clone(AblaValue value) {
    AblaSharedControl* control = shared_control(value);
    size_t current = atomic_load_explicit(&control->strong, memory_order_relaxed);
    while (true) {
        if (current == 0) panic("released Shared value", 21);
        if (current == SIZE_MAX) panic("Shared count overflow", 21);
        if (atomic_compare_exchange_weak_explicit(
                &control->strong,
                &current,
                current + 1,
                memory_order_relaxed,
                memory_order_relaxed)) break;
    }
    return value;
}

AblaValue abla_shared_get(AblaValue value) {
    return shared_control(value)->value;
}

AblaValue abla_shared_lock(AblaValue value) {
    AblaSharedControl* control = shared_control(value);
    while (atomic_exchange_explicit(
               &control->lock, 1, memory_order_acquire) != 0) {
    }
    return control->value;
}

void abla_shared_unlock(AblaValue value) {
    AblaSharedControl* control = shared_control(value);
    atomic_store_explicit(&control->lock, 0, memory_order_release);
}

AblaValue abla_shared_release(AblaValue value) {
    AblaSharedControl* control = shared_control(value);
    const size_t previous = atomic_fetch_sub_explicit(
        &control->strong, 1, memory_order_acq_rel);
    if (previous == 0) panic("released Shared value", 21);
    if (previous != 1) return abla_null();
    const AblaValue released = control->value;
    control->value = abla_null();
    const size_t previous_weak = atomic_fetch_sub_explicit(
        &control->weak, 1, memory_order_acq_rel);
    if (previous_weak == 1) abla_platform_free(control);
    return released;
}

AblaValue abla_weak_create(AblaValue value) {
    AblaSharedControl* control = shared_control(value);
    const size_t previous = atomic_fetch_add_explicit(
        &control->weak, 1, memory_order_relaxed);
    if (previous == SIZE_MAX) panic("Weak count overflow", 19);
    return (AblaValue){.tag = ABLA_WEAK, .as.weak = control};
}

AblaValue abla_weak_clone(AblaValue value) {
    AblaSharedControl* control = weak_control(value);
    const size_t previous = atomic_fetch_add_explicit(
        &control->weak, 1, memory_order_relaxed);
    if (previous == SIZE_MAX) panic("Weak count overflow", 19);
    return value;
}

AblaValue abla_weak_upgrade(AblaValue value) {
    AblaSharedControl* control = weak_control(value);
    size_t current = atomic_load_explicit(&control->strong, memory_order_acquire);
    while (current != 0) {
        if (current == SIZE_MAX) panic("Shared count overflow", 21);
        if (atomic_compare_exchange_weak_explicit(
                &control->strong,
                &current,
                current + 1,
                memory_order_acquire,
                memory_order_relaxed)) {
            return (AblaValue){.tag = ABLA_SHARED, .as.shared = control};
        }
    }
    return abla_null();
}

AblaValue abla_weak_alive(AblaValue value) {
    AblaSharedControl* control = weak_control(value);
    return abla_bool(
        atomic_load_explicit(&control->strong, memory_order_acquire) != 0);
}

AblaValue abla_weak_release(AblaValue value) {
    AblaSharedControl* control = weak_control(value);
    const size_t previous = atomic_fetch_sub_explicit(
        &control->weak, 1, memory_order_acq_rel);
    if (previous == 0) panic("released Weak value", 19);
    if (previous == 1) abla_platform_free(control);
    return abla_null();
}

AblaValue abla_negate(AblaValue value) { return abla_i64(-abla_as_i64(value)); }
AblaValue abla_not(AblaValue value) { return abla_bool(!abla_as_bool(value)); }
AblaValue abla_add(AblaValue left, AblaValue right) {
    return abla_i64(abla_as_i64(left) + abla_as_i64(right));
}
AblaValue abla_subtract(AblaValue left, AblaValue right) {
    return abla_i64(abla_as_i64(left) - abla_as_i64(right));
}
AblaValue abla_multiply(AblaValue left, AblaValue right) {
    return abla_i64(abla_as_i64(left) * abla_as_i64(right));
}
AblaValue abla_divide(AblaValue left, AblaValue right) {
    const int64_t divisor = abla_as_i64(right);
    if (divisor == 0) panic("division by zero", 16);
    return abla_i64(abla_as_i64(left) / divisor);
}
AblaValue abla_equal(AblaValue left, AblaValue right) {
    if (left.tag != right.tag) return abla_bool(false);
    switch (left.tag) {
    case ABLA_VOID:
    case ABLA_NULL: return abla_bool(true);
    case ABLA_I64: return abla_bool(left.as.i64 == right.as.i64);
    case ABLA_BOOL: return abla_bool(left.as.boolean == right.as.boolean);
    case ABLA_STRING: return abla_bool(string_equal(left.as.string, right.as.string));
    case ABLA_FUNCTION:
        return abla_bool(
            left.as.function.id == right.as.function.id &&
            left.as.function.captures == right.as.function.captures);
    case ABLA_CELL: return abla_bool(left.as.cell == right.as.cell);
    case ABLA_ARRAY: return abla_bool(left.as.array == right.as.array);
    case ABLA_OBJECT: return abla_bool(left.as.object == right.as.object);
    case ABLA_SHARED: return abla_bool(left.as.shared == right.as.shared);
    case ABLA_WEAK: return abla_bool(left.as.weak == right.as.weak);
    case ABLA_GENERATOR:
    case ABLA_TASK:
    case ABLA_THREAD:
        return abla_bool(left.as.concurrent == right.as.concurrent);
    }
    return abla_bool(false);
}
AblaValue abla_not_equal(AblaValue left, AblaValue right) {
    return abla_bool(!abla_as_bool(abla_equal(left, right)));
}
AblaValue abla_less(AblaValue left, AblaValue right) {
    return abla_bool(abla_as_i64(left) < abla_as_i64(right));
}
AblaValue abla_less_equal(AblaValue left, AblaValue right) {
    return abla_bool(abla_as_i64(left) <= abla_as_i64(right));
}
AblaValue abla_greater(AblaValue left, AblaValue right) {
    return abla_bool(abla_as_i64(left) > abla_as_i64(right));
}
AblaValue abla_greater_equal(AblaValue left, AblaValue right) {
    return abla_bool(abla_as_i64(left) >= abla_as_i64(right));
}

AblaValue abla_to_string(AblaValue value) {
    if (value.tag == ABLA_STRING) return value;
    if (value.tag == ABLA_NULL) return abla_string_static("null", 4);
    if (value.tag == ABLA_BOOL) {
        return value.as.boolean
            ? abla_string_static("true", 4)
            : abla_string_static("false", 5);
    }
    if (value.tag != ABLA_I64) panic("value is not printable", 22);
    char reversed[21];
    size_t count = 0;
    uint64_t magnitude;
    const bool negative = value.as.i64 < 0;
    if (negative) {
        magnitude = (uint64_t)(-(value.as.i64 + 1)) + 1;
    } else {
        magnitude = (uint64_t)value.as.i64;
    }
    do {
        reversed[count++] = (char)('0' + magnitude % 10);
        magnitude /= 10;
    } while (magnitude != 0);
    const size_t length = count + (negative ? 1u : 0u);
    char* text = (char*)abla_platform_alloc(length + 1);
    size_t output = 0;
    if (negative) text[output++] = '-';
    while (count != 0) text[output++] = reversed[--count];
    text[length] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = text,
            .length = length,
            .owner = text,
            .rope = (AblaStringRope*)0}};
}

AblaValue abla_string_concat(AblaValue left, AblaValue right) {
    if (left.tag != ABLA_STRING || right.tag != ABLA_STRING) {
        panic("concat expects strings", 22);
    }
    if (left.as.string.length == 0) return right;
    if (right.as.string.length == 0) return left;
    if (left.as.string.length > SIZE_MAX - right.as.string.length) {
        panic("string length overflow", 22);
    }
    const size_t length = left.as.string.length + right.as.string.length;
    AblaStringRope* rope =
        (AblaStringRope*)abla_platform_alloc(sizeof(AblaStringRope));
    abla_platform_memory_set_layout(rope, 6);
    rope->left = left.as.string;
    rope->right = right.as.string;
    rope->flattened = (char*)0;
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = (const char*)0,
            .length = length,
            .owner = (const char*)0,
            .rope = rope}};
}

AblaValue abla_string_length(AblaValue value) {
    if (value.tag != ABLA_STRING) panic("expected string", 15);
    if (value.as.string.length > (size_t)INT64_MAX) {
        panic("string length does not fit in int", 32);
    }
    return abla_i64((int64_t)value.as.string.length);
}

AblaValue abla_string_get(AblaValue value, AblaValue index_value) {
    if (value.tag != ABLA_STRING) panic("expected string", 15);
    const int64_t index = abla_as_i64(index_value);
    if (index < 0 || (uint64_t)index >= value.as.string.length) {
        panic("string index out of bounds", 26);
    }
    return abla_i64(
        (int64_t)(uint8_t)string_data(value.as.string)[(size_t)index]);
}

AblaValue abla_string_slice(
    AblaValue value,
    AblaValue begin_value,
    AblaValue end_value) {
    if (value.tag != ABLA_STRING) panic("expected string", 15);
    const int64_t begin = abla_as_i64(begin_value);
    const int64_t end = abla_as_i64(end_value);
    if (begin < 0 || end < begin || (uint64_t)end > value.as.string.length) {
        panic("string slice is out of bounds", 29);
    }
    if (begin == 0 && (uint64_t)end == value.as.string.length) return value;
    const size_t length = (size_t)(end - begin);
    if (length == 0) return abla_string_static("", 0);
    const char* data = string_data(value.as.string);
    const char* owner = value.as.string.owner;
    if (owner == (const char*)0 && value.as.string.rope != NULL) owner = data;
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = data + (size_t)begin,
            .length = length,
            .owner = owner,
            .rope = (AblaStringRope*)0}};
}

AblaValue ablaUtf8EncodeScalar(AblaValue value) {
    const int64_t scalar = abla_as_i64(value);
    if (scalar < 0 || scalar > 0x10ffff ||
        (scalar >= 0xd800 && scalar <= 0xdfff)) {
        return abla_string_static("", 0);
    }
    char encoded[4];
    size_t length = 0;
    if (scalar <= 0x7f) {
        encoded[0] = (char)scalar;
        length = 1;
    } else if (scalar <= 0x7ff) {
        encoded[0] = (char)(0xc0 | (scalar >> 6));
        encoded[1] = (char)(0x80 | (scalar & 0x3f));
        length = 2;
    } else if (scalar <= 0xffff) {
        encoded[0] = (char)(0xe0 | (scalar >> 12));
        encoded[1] = (char)(0x80 | ((scalar >> 6) & 0x3f));
        encoded[2] = (char)(0x80 | (scalar & 0x3f));
        length = 3;
    } else {
        encoded[0] = (char)(0xf0 | (scalar >> 18));
        encoded[1] = (char)(0x80 | ((scalar >> 12) & 0x3f));
        encoded[2] = (char)(0x80 | ((scalar >> 6) & 0x3f));
        encoded[3] = (char)(0x80 | (scalar & 0x3f));
        length = 4;
    }
    char* result = (char*)abla_platform_alloc(length + 1);
    copy_bytes(result, encoded, length);
    result[length] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = result,
            .length = length,
            .owner = result,
            .rope = (AblaStringRope*)0}};
}

AblaValue ablaTextFindSequence(
    AblaValue text,
    AblaValue sequence,
    AblaValue begin_value,
    AblaValue end_value) {
    if (text.tag != ABLA_STRING || sequence.tag != ABLA_STRING) {
        panic("text search expects strings", 27);
    }
    const int64_t begin = abla_as_i64(begin_value);
    const int64_t end = abla_as_i64(end_value);
    if (begin < 0 || end < begin || (uint64_t)end > text.as.string.length) {
        return abla_i64(-1);
    }
    const size_t first = (size_t)begin;
    const size_t limit = (size_t)end;
    const size_t wanted = sequence.as.string.length;
    if (wanted == 0) return abla_i64(begin);
    if (wanted > limit - first) return abla_i64(-1);
    const char* source = string_data(text.as.string);
    const char* needle = string_data(sequence.as.string);
    size_t index = first;
    const size_t last = limit - wanted;
    while (index <= last) {
        if (source[index] == needle[0] &&
            (wanted == 1 || equal_bytes(source + index, needle, wanted))) {
            return abla_i64((int64_t)index);
        }
        ++index;
    }
    return abla_i64(-1);
}

AblaValue ablaTextFindByte(
    AblaValue text,
    AblaValue byte_value,
    AblaValue begin_value,
    AblaValue end_value) {
    if (text.tag != ABLA_STRING) panic("byte search expects text", 24);
    const int64_t byte = abla_as_i64(byte_value);
    const int64_t begin = abla_as_i64(begin_value);
    const int64_t end = abla_as_i64(end_value);
    if (byte < 0 || byte > 255 || begin < 0 || end < begin ||
        (uint64_t)end > text.as.string.length) {
        return abla_i64(-1);
    }
    const char* source = string_data(text.as.string);
    size_t index = (size_t)begin;
    const size_t limit = (size_t)end;
    while (index < limit && (uint8_t)source[index] != (uint8_t)byte) ++index;
    return abla_i64(index < limit ? (int64_t)index : -1);
}

AblaValue ablaTextAsciiEqualInsensitive(AblaValue left, AblaValue right) {
    if (left.tag != ABLA_STRING || right.tag != ABLA_STRING) {
        panic("ASCII comparison expects strings", 32);
    }
    if (left.as.string.length != right.as.string.length) {
        return abla_bool(false);
    }
    const char* left_data = string_data(left.as.string);
    const char* right_data = string_data(right.as.string);
    size_t index = 0;
    while (index < left.as.string.length) {
        uint8_t left_byte = (uint8_t)left_data[index];
        uint8_t right_byte = (uint8_t)right_data[index];
        if (left_byte >= 'A' && left_byte <= 'Z') left_byte += 'a' - 'A';
        if (right_byte >= 'A' && right_byte <= 'Z') right_byte += 'a' - 'A';
        if (left_byte != right_byte) return abla_bool(false);
        ++index;
    }
    return abla_bool(true);
}

AblaValue ablaTextReadU32LittleEndian(AblaValue text, AblaValue offset_value) {
    if (text.tag != ABLA_STRING) panic("byte decoding expects text", 26);
    const int64_t offset = abla_as_i64(offset_value);
    if (offset < 0 || (uint64_t)offset > text.as.string.length ||
        text.as.string.length - (size_t)offset < 4) {
        return abla_i64(-1);
    }
    const uint8_t* bytes =
        (const uint8_t*)string_data(text.as.string) + (size_t)offset;
    return abla_i64((int64_t)(
        (uint32_t)bytes[0] |
        (uint32_t)bytes[1] << 8 |
        (uint32_t)bytes[2] << 16 |
        (uint32_t)bytes[3] << 24));
}

AblaValue ablaBitAnd(AblaValue left, AblaValue right) {
    return abla_i64(abla_as_i64(left) & abla_as_i64(right));
}

AblaValue ablaBitOr(AblaValue left, AblaValue right) {
    return abla_i64(abla_as_i64(left) | abla_as_i64(right));
}

AblaValue ablaBitXor(AblaValue left, AblaValue right) {
    return abla_i64(abla_as_i64(left) ^ abla_as_i64(right));
}

AblaValue ablaBitNot(AblaValue value) {
    return abla_i64(~abla_as_i64(value));
}

AblaValue ablaBitShiftLeft(AblaValue value, AblaValue count_value) {
    const int64_t count = abla_as_i64(count_value);
    if (count < 0 || count >= 64) return abla_i64(0);
    return abla_i64((int64_t)((uint64_t)abla_as_i64(value) << count));
}

AblaValue ablaBitShiftRight(AblaValue value, AblaValue count_value) {
    const int64_t count = abla_as_i64(count_value);
    if (count < 0 || count >= 64) return abla_i64(0);
    const int64_t input = abla_as_i64(value);
    if (count == 0 || input >= 0) {
        return abla_i64((int64_t)((uint64_t)input >> count));
    }
    const uint64_t shifted = ((uint64_t)input >> count) |
        (UINT64_MAX << (64 - count));
    return abla_i64((int64_t)shifted);
}

AblaValue ablaBitShiftRightUnsigned(
    AblaValue value,
    AblaValue count_value) {
    const int64_t count = abla_as_i64(count_value);
    if (count < 0 || count >= 64) return abla_i64(0);
    return abla_i64((int64_t)((uint64_t)abla_as_i64(value) >> count));
}

AblaValue ablaByteEncode(AblaValue value) {
    const int64_t byte = abla_as_i64(value);
    if (byte < 0 || byte > 255) return abla_string_static("", 0);
    char* result = (char*)abla_platform_alloc(2);
    result[0] = (char)(uint8_t)byte;
    result[1] = '\0';
    return (AblaValue){
        .tag = ABLA_STRING,
        .as.string = {
            .data = result,
            .length = 1,
            .owner = result,
            .rope = (AblaStringRope*)0}};
}

AblaValue abla_length(AblaValue value) {
    if (value.tag == ABLA_STRING) return abla_string_length(value);
    if (value.tag == ABLA_ARRAY) return abla_array_length(value);
    panic("value has no length", 19);
}

AblaValue abla_index_get(AblaValue value, AblaValue index) {
    if (value.tag == ABLA_STRING) return abla_string_get(value, index);
    if (value.tag == ABLA_ARRAY) return abla_array_get(value, index);
    panic("value is not indexable", 22);
}

AblaValue abla_array_create(const AblaValue* values, size_t count) {
    if (count > SIZE_MAX / sizeof(AblaValue)) {
        panic("array allocation overflow", 25);
    }
    AblaArray* array = (AblaArray*)abla_platform_alloc(
        sizeof(AblaArray) + count * sizeof(AblaValue));
    abla_platform_memory_set_layout(array, 4);
    array->length = count;
    array->capacity = count;
    array->values = count == 0 ? (AblaValue*)0 : (AblaValue*)(array + 1);
    for (size_t index = 0; index < count; ++index) array->values[index] = values[index];
    return (AblaValue){.tag = ABLA_ARRAY, .as.array = array};
}
AblaValue abla_array_length(AblaValue value) {
    if (value.tag != ABLA_ARRAY) panic("expected array", 14);
    if (value.as.array->length > (size_t)INT64_MAX) {
        panic("array length does not fit in int", 32);
    }
    return abla_i64((int64_t)value.as.array->length);
}
AblaValue abla_array_append(AblaValue value, AblaValue element) {
    if (value.tag != ABLA_ARRAY) panic("expected array", 14);
    AblaArray* array = value.as.array;
    if (array->length == array->capacity) {
        if (array->capacity > SIZE_MAX / 2) panic("array capacity overflow", 23);
        const size_t capacity = array->capacity == 0 ? 4 : array->capacity * 2;
        if (capacity > SIZE_MAX / sizeof(AblaValue)) {
            panic("array allocation overflow", 25);
        }
        AblaValue* values =
            (AblaValue*)abla_platform_alloc(sizeof(AblaValue) * capacity);
        abla_platform_memory_set_layout(values, 2);
        for (size_t index = 0; index < array->length; ++index) {
            values[index] = array->values[index];
        }
        if (array->values != (AblaValue*)0 &&
            array->values != (AblaValue*)(array + 1)) {
            abla_platform_free(array->values);
        }
        array->values = values;
        array->capacity = capacity;
    }
    array->values[array->length++] = element;
    return abla_void();
}
AblaValue abla_array_get(AblaValue value, AblaValue index_value) {
    if (value.tag != ABLA_ARRAY) panic("expected array", 14);
    const int64_t index = abla_as_i64(index_value);
    if (index < 0 || (uint64_t)index >= value.as.array->length) {
        panic("array index out of bounds", 25);
    }
    return value.as.array->values[index];
}
void abla_array_set(AblaValue value, AblaValue index_value, AblaValue element) {
    if (value.tag != ABLA_ARRAY) panic("expected array", 14);
    const int64_t index = abla_as_i64(index_value);
    if (index < 0 || (uint64_t)index >= value.as.array->length) {
        panic("array index out of bounds", 25);
    }
    value.as.array->values[index] = element;
}

AblaValue abla_object_create(uint32_t type_symbol, size_t field_count) {
    if (field_count > (SIZE_MAX - sizeof(AblaObject)) / sizeof(AblaField)) {
        panic("object field count overflow", 27);
    }
    AblaObject* object = (AblaObject*)abla_platform_alloc(
        sizeof(AblaObject) + field_count * sizeof(AblaField));
    abla_platform_memory_set_layout(object, 5);
    object->type_symbol = type_symbol;
    object->count = 0;
    object->capacity = field_count;
    object->fields = field_count == 0
        ? (AblaField*)0
        : (AblaField*)(object + 1);
    return (AblaValue){.tag = ABLA_OBJECT, .as.object = object};
}
AblaValue abla_field_get(AblaValue value, uint32_t field_symbol) {
    if (value.tag != ABLA_OBJECT) panic("expected object", 15);
    for (size_t index = 0; index < value.as.object->count; ++index) {
        if (value.as.object->fields[index].symbol == field_symbol) {
            return value.as.object->fields[index].value;
        }
    }
    panic("object field is uninitialized", 29);
}
void abla_field_initialize(
    AblaValue value,
    uint32_t field_symbol,
    AblaValue field_value) {
    if (value.tag != ABLA_OBJECT) panic("expected object", 15);
    AblaObject* object = value.as.object;
    if (object->count >= object->capacity) {
        panic("too many initialized object fields", 34);
    }
    object->fields[object->count++] = (AblaField){field_symbol, field_value};
}
void abla_field_set(AblaValue value, uint32_t field_symbol, AblaValue field_value) {
    if (value.tag != ABLA_OBJECT) panic("expected object", 15);
    AblaObject* object = value.as.object;
    for (size_t index = 0; index < object->count; ++index) {
        if (object->fields[index].symbol == field_symbol) {
            object->fields[index].value = field_value;
            return;
        }
    }
    if (object->count == object->capacity) {
        const size_t capacity = object->capacity == 0 ? 4 : object->capacity * 2;
        AblaField* fields = (AblaField*)abla_platform_alloc(sizeof(AblaField) * capacity);
        abla_platform_memory_set_layout(fields, 3);
        for (size_t index = 0; index < object->count; ++index) fields[index] = object->fields[index];
        if (object->fields != (AblaField*)0 &&
            object->fields != (AblaField*)(object + 1)) {
            abla_platform_free(object->fields);
        }
        object->fields = fields;
        object->capacity = capacity;
    }
    object->fields[object->count++] = (AblaField){field_symbol, field_value};
}
