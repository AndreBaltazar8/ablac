# ablac - compiler for abla programming language

abla is a programming language that allows arbitrary compile-time code execution. It will also allow compile-time modification of code. 

Another long term goal of the language is also to allow new code to be inserted dynamically into compiled programs. Effectively allowing patching and modification of programs at every stage from compilation to execution, which enables a wide range of opportunities.

The language is not beginner friendly. It is constructed to allow easier construction of complex systems, with features like allowing code modification and reducing the amount of boilerplate code.

# Example

An example of usage of compile-time code execution:

```
extern:"c" fun printf(fmt: string): int

fun main {
    #printf("I'm run at compile-time")
    printf("I'm run at runtime")
}
```

# Features

These the current and planned features for the language. It is not exhaustive list of what is planned and serves as a guide for what needs to be worked on next. 

## Current Features
- Basic function declaration handling
- Basic string support
- Basic function calls
- Hardcoded function lambda functionality
- Import new file
- Parallel processing of imported files
- compile-time execution for all available features

## To Do
- Build string properly from AST
- Add operators
- If/else
- Switch/When
- Loops
- Types in functions to AST
- Type checking everything
- Class object allocation
- Class construction
- Extension functions
- Variable declarations (in functions, globally and class fields)
- Send values to lambdas and other scopes
- Call to methods in classes
- Sending compiler context to functions with "compile" modifier
  * Allow reading compiler info
  * Allow modification of code
- Pointers
  * Declaration - A pointer to a type is indicated by a `*` after the type of the value the pointer is pointing at. For example a pointer to a `int` value is `int*`. This goes against the fact that types are on the right side of variables parameters, but we want to auto dereference pointers.
  * Getting addresses - Either use `&` or `*` to get the address. `*` goes against C, but is a more natural way of thinking about the address of a value, since `*` already represents the pointer to a value in a type.
  * De-referencing - Done automatically when used, but can also use `*` or `&` (pending discussion on the point above) for de-referencing it explicitly.
  * Destruction - Create some function to allow destruction of objects referenced under pointers
  * Weak references - Allow pointers that allow asserting if the values have been freed.
- Memory Management
  * Garbage collected (allow different collection methods, eg. ref counting and destruction, or late )
  * Getting pointers to object makes it no longer collect automatically and must be destroyed manually
- Implementing standard lib 
  * networking and http stack
  * math lib
  * threading
