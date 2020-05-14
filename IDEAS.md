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
compiler fun wrapFunction(function: #function, wrap: #functionLiteral) {
    val functionBlock = function.block
    // the follow syntax is likely to be different
    function.block = wrap.block.findAll { it == #functionCall("it") }
        .replaceWithMultiple { functionBlock.statements }
}

fun hi {
    printf("Hello")
}

compiler fun wrapHi() {
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
