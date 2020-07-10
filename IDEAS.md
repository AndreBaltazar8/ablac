# Ideas for differentiating features

This is a random assortment of ideas and features that could (and most likely will) be include in abla.

## Compile Time Code Execution

Allow compilation of code at compile time to modify any part of the code that is going to be compiled and the process of compilation itself. This is achieved by an intermediate step between type gather/verification and machine code generation in the backend.

The language is already implementing this feature through an interpretation visitor that executes the code being compiled.

The final objective is to be able to run any part of the code at compile time, and it should be completely indifferent for a developer to develop code for compile time vs run time. Every library defined for run time, should work the same at compile time even using external functions. It should be possible to run a complete HTTP server at compile time for example.

### Example

Printing text at both compile and run time

```
fun main {
    #printf("Hello from compiler")
    printf("Hello from run time")
}
```

Calling a class at compile time
```
class Hello(val world: String) {
    fun print(hello: String) = printf("$hello $world")
}
fun main {
    #Hello("compiler").print("hello") // outputs: hello compiler
    Hello("run time").print("hello") // outputs: hello run time
}
```

Code modification (illustrative example)

```
compile fun wrapFunction(function: #function, wrap: #functionLiteral) {
    val functionBlock = function.block
    // the follow syntax is likely to be different
    function.block = wrap.block.findAll { it == #functionCall("it") }
        .replaceWithMultiple { functionBlock.statements }
}

fun hi {
    printf("Hello")
}

compile fun wrapHi() {
    wrapFunction(compiler.getFunction("hi")) {
        it()
        printf(" World")
    }
} 

#wrapHi()

fun main {
    hi() // outputs: Hello World
}
```

## Delegator Access for Delegated Properties

We should be able to access the delegator of delegated properties, to call functions on them and make it transparent to both assign values and do other behaviours that might modify the property setters and getters in the future.

Kotlin has the concept of delegated properties where you can basically delegate the value of a property to another class. This creates behaviours like Lazy values very easily. Here is an example:

```
class LazyInt(val initialization: () -> Int) {
    lateinit var value: Int;
    
    operator fun getValue(thisRef: Any?, property: KProperty<*>): Int {
        if (::value.isInitialized)
            return value
        
        value = initialization()
        return value
    } 
}

class Foo {
    val bar by LazyInt { 5 * 5 }
}

fun main() {
    val foo = Foo()
    print(foo.bar)
    print(foo.bar)
}
```

The first call to the `foo.bar` property would compute the value. The second call would only get the stored value. Now lets take this to the next level.

Imagine if it was possible to call things on the delegate itself. Let's say I have a property that I want to be watchable, I want some consumers of this property to be able to just assign values to it, while others can watch it. I would create something like.

```
class Foo {
    val bar = ObservableInt(1)
}
```

This class can be both observed and assigned values into, as it works as a normal class. I would just have to call some method or property in it to assign values, and some other function to watch the value changes.

```
fun main {
    val foo = Foo()
    foo.bar.watch { oldValue, newValue ->
        printf("bar changed from $oldValue to $newValue")
    }
    foo.bar.value = 5
}
```

This would work okay, but everyone involved would need to know that the value is actually an observable value. What if we could eliminate the `.value`. This is where the idea comes in.

We would have the observable as a delegated property:

```
class Foo {
    val bar by ObservableInt(1)
}
```

This would allow setting and getting the value, but the delegate is inaccessible. The idea is to be able to access the delegate from a special syntax and allow function calls to it, and maybe even allow replacing the delegate itself.

```
fun main() {
    val foo = Foo()
    foo.bar!.watch { oldValue, newValue ->
        printf("bar changed from $oldValue to $newValue")
    }
    foo.bar = 5
    foo.bar!.value = 10
}
```

The `!.` (of course this might change) would serve as access to the delegate itself, and you would be able to call functions on it as any normal class.

This feature is available in Kotlin for JVM and JS but you need to get to it with reflection. It would be part of the language and almost transparent. The values themselves could possible pass the delegate along to be accessible in at later stages, for example:

```
fun main() {
    val foo = Foo()
    val bar = foo.bar
    bar!.value = 3
}
```

It's debatable here if `bar` should have the delegate for `foo.bar` or not because `bar` itself could have a delegate. It's even worse while passing it into functions like:

```
fun test(bar: int) {
    bar!.value = 3 // should we be able to access the delegate here? probably not
}

fun main {
    val foo = Foo()
    test(foo.bar)
}
``` 

The concept itself is great for this case of Observables, but could also serve as a way to allow more modification of class behaviour at run time.
