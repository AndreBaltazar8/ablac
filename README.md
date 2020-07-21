# ablac - compiler for abla programming language

Abla's mission is to **make compile time as important as runtime**. Why? Because complex systems can be created from simple code, but that simple code is not always possible and sometimes requires complex code generators written in different languages. Why not have the power to generate that code from the same language you are writing, and without complications?

How is this done? By **allowing every piece of code to run at compile time** if needed. Functions can access the compiler context which gives the ability not only to generate new code, but also modify any part of the program being compiled. Any compile time expression can be used to build a constant value.

So what is abla exactly? **Abla is new programming language which allows arbitrary code execution at compile time**. Anything that can run at runtime, is also available at compile time. It allows modifications of the code being compiled, and even allows modification of other compile time code. 

Another long term goal of the language is also to allow new code to be inserted dynamically into compiled programs. Effectively allowing patching and modification of programs at every stage from compilation to execution, which enables a wide range of applications.

The language is not beginner friendly. It contains advanced features like code modification which can be difficult to understand for beginners but give the programmer a great deal of power specially allowing to reduce the amount of boilerplate code that needs to be written, when compared with other systems that allow generation of code.

Kotlin heavily influenced the syntax for abla, however during initial development any part can be modified. Major versions of the language will probably also break the syntax or other parts of applications that are developed in previous major versions. The philosophy here is to allow experimentation with features that are not available on other languages but could greatly increase the power of the programming language and the programmers using it.

## Example

An example of usage of compile-time code execution:

```abla
extern:"c" fun printf(fmt: string): int

fun main {
    #printf("I'm run at compile-time")
    printf("I'm run at runtime")
}
```
(this example runs but its using some magic for handling printf variadic args)

Some fun stuff to do with abla in the future:
```abla
/*
 * Some notes:
 *  - Lambdas with only one parameter declare implicit ´it´ variable
 *  - ´#´ signals the start of a compile-time expression
 *  - Functions with compile modifier are only available at compile time, and can access functions from the compiler
 *  - Function literals called direcly by the compile directive ´#´, can also access compile functions
 */

// Extend import to allow libraries
compile fun lib(name: String, provider: ((name: String) -> void)? = null) {
    if (provider)
        import("$name/entry.ab")
    else
        provider(name)
}

compile fun git(name: string) {
    // checkout and import code from git repo by name in your favorite provider
}

#lib("abla/stdlib")
#lib("abla/mvc", git)

class PrintPerformance

@PrintPerformance
fun safeCall(block: () -> void) {
    try {
        block()
    } catch (e: Exception) {
    }
}

// We will call a function literal at compile time
#{
    /*
     * The syntax is bound to change. This is just an example of how we could modify a function at compile time. It
     * won't be much different than this, but the API is not yet defined.
     */
    compile.functions.filter { it.hasAnnotation<PrintPerformance>() }.wrapBody {
        val start = Time.now()
        it.call()
        println("took: ${Time.since(start).toNano()}ns")
    }
}()

class MyIPResponse(val address: string)
class MyIPResponseV2(val address: string, val location: string)

@route("myip")
class IPLookupAPI(
  @inject val locationService: ILocationService
) : API {
  @version(1)
  fun myip = MyIPResponse(request.remoteaddr.toString())

  @version(2)
  fun myip = previous().let {
    MyIPResponseV2(it.address, locationService.lookupLocation(it.address))
  }

  /*
   * Two methods declared with same name but different annotation. The API library would sort these out at compile time
   * and produce an versioned API to that route.
   */
}

fun main {
    // Passing lambdas easily as last parameter
    safeCall {
        throw Exception("I won't blow up")
    }
}
```

The test from the `runner` module is the main test which contains the full features available at the moment. When it is run, it produces a single file called `file.bc` with the LLVM bitcode. This can be linked into a working program by running `clang file.bc -o main`.

## Features

These the current and planned features for the language. It is not exhaustive list of what is planned and serves as a guide for what needs to be worked on next. 

### Current Features
- Basic function declaration handling
- Basic string support
- Basic function calls
- Basic operators and comparison for int
- Basic support for if-else expressions/statements
- Basic variable declarations
- Basic array support
- Hardcoded function lambda functionality
- Import new file
- Parallel processing of imported files
- `while`, `do-while` loops
- `when` expressions
- Basic type inference
- Class instantiation with simple variables
- Class method calls (no vtable)
- Calls to external libraries
- Extension functions
- compile-time execution for all available features with interpretation execution

### To Do
- Investigate:
  * Converting from ANTLR contexts to nodes
  * Storing LLVM nodes and other data on Nodes
  * Storing info about types
  * More performant way of executing compile-time code
- Support outputting file with correct name
- Support strings with expressions at runtime
- Support `const char*` from C as native type that can be used in abla even though strings in abla will probably not be simple null-terminated strings
  * Creating a new built-in type that allows automatic conversion between `const char*` and `string` implementation in abla
- Add operators and comparisons for all types
- Loops (for)
- Add simple built-in types (string, int)
- Support extensions for built-in types
- Virtual methods for polymorphism and overrides
- Type checking everything
- Class object allocation
- Class construction with proper constructors
- Extension properties
- Variable declarations with type check (in functions, globally and class fields)
- Type inference algorithm
- Send values to lambdas and other scopes
  * Don't allow to call functions that capture context before it is declared in another function
- Sending compiler context to functions with "compile" modifier
  * Allow reading compiler info
  * Allow modification of code
- Pointers
  * Declaration - `*` after the type of the value defines a pointer to that type. For example a pointer to a `int` value is `int*`. This goes against the fact that types are on the right side of variables parameters, but its easier to understand the underlying type since pointers can be automatically de-referenced.
  * Getting addresses - Either use `&` or `*` to get the address. `*` goes against C, but is a more natural way of thinking about the address of a value, since `*` already represents the pointer to a value in a type.
  * De-referencing - Done automatically when used, but can also use `*` or `&` (pending investigation on the point above) for de-referencing it explicitly.
  * Destruction - Create some function to allow destruction of objects referenced under pointers
  * Weak references - Allow pointers that allow asserting if the values have been freed.
- Memory Management
  * Garbage collected (allow different collection methods, eg. ref counting and destruction, or late )
  * Getting pointers to object makes it no longer collect automatically and must be destroyed manually
- Implementing standard lib 
  * networking and http stack
  * math lib
  * threading
  
### Things to try
- Multiple language parsing
  * Try to switch based on executing code
- Self modification at run time
- Removing main function and use file as main function

## Contributing

There is a lot of work to be done here. If you would like to contribute, please reach out or submit your contribution in a pull request.

If it's your first contribution, please also include your name and email in the AUTHORS file in the first commit of the PR. By contributing you accept the LICENSE of the project and that your contributions will be distributed under it.
