package dev.ablac.processor

import com.google.auto.service.AutoService
import com.squareup.kotlinpoet.*
import dev.ablac.annotations.NodeUnused
import java.io.File
import javax.annotation.processing.*
import javax.lang.model.SourceVersion
import javax.lang.model.element.ElementKind
import javax.lang.model.element.TypeElement

@AutoService(Processor::class)
@SupportedSourceVersion(SourceVersion.RELEASE_11)
@SupportedAnnotationTypes("dev.ablac.annotations.NodeUnused")
@SupportedOptions(NodeProcessor.KAPT_KOTLIN_GENERATED_OPTION_NAME)
class NodeProcessor : AbstractProcessor() {
    companion object {
        const val KAPT_KOTLIN_GENERATED_OPTION_NAME = "kapt.kotlin.generated"
    }

    override fun process(annotations: MutableSet<out TypeElement>, roundEnv: RoundEnvironment): Boolean {
        val generatedSourcesRoot: String = processingEnv.options[KAPT_KOTLIN_GENERATED_OPTION_NAME].orEmpty()
        if(generatedSourcesRoot.isEmpty()) {
            processingEnv.messager.errorMessage { "Can't find the target directory for generated Kotlin files." }
            return false
        }

        roundEnv.getElementsAnnotatedWith(NodeUnused::class.java).forEach { element ->
            if (element.kind != ElementKind.CLASS) {
                processingEnv.messager.errorMessage { "Can only be applied to classes, element: $element" }
                return false
            }

            val packageName = processingEnv.elementUtils.getPackageOf(element).toString()

            val clazz = element as TypeElement

            val funBuilder = FunSpec.builder("accept")
                .receiver(ClassName(packageName, clazz.simpleName.toString()))
                .addParameter("visitor", ClassName("dev.ablac.language", "ASTVisitor"))
                .addStatement("visitor.visit(this)")

            val file = File(generatedSourcesRoot)
            file.mkdir()
            FileSpec.builder(packageName, "${clazz.simpleName}Extension")
                .addFunction(funBuilder.build())
                .build()
                .writeTo(file)
        }
        return true
    }
}