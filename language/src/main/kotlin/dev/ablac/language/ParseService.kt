package dev.ablac.language

import dev.ablac.grammar.AblaLexer
import dev.ablac.grammar.AblaParser
import dev.ablac.language.nodes.File
import dev.ablac.utils.MeasurementScope
import org.antlr.v4.runtime.CharStream
import org.antlr.v4.runtime.CharStreams
import org.antlr.v4.runtime.CommonTokenStream
import java.io.IOException
import java.io.InputStream
import java.lang.RuntimeException

interface IParseService {
    suspend fun parseFile(fileName: String, measurementScope: MeasurementScope) : File
    suspend fun parseSource(name: String, source: String, measurementScope: MeasurementScope) : File
    suspend fun parseStream(name: String, stream: InputStream, measurementScope: MeasurementScope) : File
}

class ParseService : IParseService {
    override suspend fun parseFile(fileName: String, measurementScope: MeasurementScope): File {
        return parse(fileName, { CharStreams.fromFileName(fileName) }, measurementScope)
    }

    override suspend fun parseSource(name: String, source: String, measurementScope: MeasurementScope): File {
        return parse(name, { CharStreams.fromString(source) }, measurementScope)
    }

    override suspend fun parseStream(name: String, stream: InputStream, measurementScope: MeasurementScope): File {
        return parse(name, { CharStreams.fromStream(stream) }, measurementScope)
    }

    private suspend fun parse(fileName: String, stream: () -> CharStream, measurementScope: MeasurementScope) : File {
        return measurementScope.measure("parse total") { newMeasureScope ->
            val parser = newMeasureScope.measure("setup") {
                val charStream = try {
                    stream()
                } catch (e: IOException) {
                    throw RuntimeException()
                }

                val lexer = AblaLexer(charStream)
                val tokenStream = CommonTokenStream(lexer)
                AblaParser(tokenStream)
            }

            val parsedFile = newMeasureScope.measure("parse") { parser.file() }
            newMeasureScope.measure("ast convert") { parsedFile.toAST(fileName) }
        }
    }
}
