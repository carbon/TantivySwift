import Foundation
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct TantivyMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [IndexableMacro.self, FieldMacro.self]
}

private struct MacroError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// `@Field` is a marker read by `@Indexable`; it expands to nothing on its own.
public struct FieldMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// `@Indexable` derives `IndexableDocument` (a `searchSchema`) from the struct's
/// `@Field`-marked stored properties.
public struct IndexableMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        var lines: [String] = []
        for member in declaration.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let fieldAttr = fieldAttribute(in: varDecl.attributes)
            else { continue }

            guard let binding = varDecl.bindings.first,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let fieldType = binding.typeAnnotation?.type
            else {
                throw MacroError("@Field property needs an explicit type annotation")
            }
            lines.append(try schemaCall(name: name, type: fieldType,
                                        options: FieldOptions(attribute: fieldAttr)))
        }

        let chain = (["SchemaBuilder()"] + lines + [".build()"])
            .joined(separator: "\n            ")

        let ext = try ExtensionDeclSyntax(
            """
            extension \(type.trimmed): IndexableDocument {
                public static var searchSchema: Schema {
                    \(raw: chain)
                }
            }
            """
        )
        return [ext]
    }
}

// MARK: - helpers

private func fieldAttribute(in attributes: AttributeListSyntax) -> AttributeSyntax? {
    for element in attributes {
        if case .attribute(let attr) = element,
           attr.attributeName.trimmedDescription == "Field" {
            return attr
        }
    }
    return nil
}

private struct FieldOptions {
    var stored = true
    var indexed = true
    var fast = false
    var analyzer: String?   // expression text, e.g. ".english"

    init(attribute: AttributeSyntax) {
        guard let args = attribute.arguments?.as(LabeledExprListSyntax.self) else { return }
        for arg in args {
            switch arg.label?.text {
            case "stored": stored = boolLiteral(arg.expression) ?? stored
            case "indexed": indexed = boolLiteral(arg.expression) ?? indexed
            case "fast": fast = boolLiteral(arg.expression) ?? fast
            case "analyzer": analyzer = arg.expression.trimmedDescription
            default: break
            }
        }
    }
}

private func boolLiteral(_ expr: ExprSyntax) -> Bool? {
    expr.as(BooleanLiteralExprSyntax.self).map { $0.literal.text == "true" }
}

/// Map a property's type + `@Field` options to a `SchemaBuilder` call.
private func schemaCall(name: String, type: TypeSyntax, options: FieldOptions) throws -> String {
    // Unwrap optional and array wrappers (a `[String]` indexes like `String`,
    // multi-valued).
    var t = type.trimmedDescription
    if t.hasSuffix("?") { t.removeLast() }
    t = t.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("["), t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
    if t.hasSuffix("?") { t.removeLast() }
    t = t.trimmingCharacters(in: .whitespaces)

    let s = options.stored, i = options.indexed, f = options.fast
    switch t {
    case "String":
        let analyzer = options.analyzer ?? ".default"
        return ".addTextField(\"\(name)\", stored: \(s), indexed: \(i), tokenizer: \(analyzer), fast: \(f))"
    case "UInt64", "UInt", "UInt32", "UInt16", "UInt8":
        return ".addU64Field(\"\(name)\", stored: \(s), indexed: \(i), fast: \(f))"
    case "Int64", "Int", "Int32", "Int16", "Int8":
        return ".addI64Field(\"\(name)\", stored: \(s), indexed: \(i), fast: \(f))"
    case "Double", "Float":
        return ".addF64Field(\"\(name)\", stored: \(s), indexed: \(i), fast: \(f))"
    case "Bool":
        return ".addBoolField(\"\(name)\", stored: \(s), indexed: \(i), fast: \(f))"
    case "Date":
        return ".addDateField(\"\(name)\", stored: \(s), indexed: \(i), fast: \(f))"
    default:
        throw MacroError("@Field: unsupported type '\(t)' for property '\(name)'")
    }
}
