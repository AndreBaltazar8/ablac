plugins {
    `java-library`
    antlr
}

dependencies {
    antlr(Dependencies.ANTLR)
}

tasks.generateGrammarSource {
    maxHeapSize = "64m"
    arguments = arguments + listOf("-visitor", "-long-messages", "-package", "dev.abla.grammar")
}
tasks.getByName("compileJava")
    .dependsOn("generateGrammarSource")