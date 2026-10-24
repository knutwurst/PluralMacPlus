//
//  LaunchOptionsEditor.swift
//  PluralMac
//
//  Created by Knutwurst on 13.10.26.
//

import SwiftUI

/// Edits custom environment variables and command-line arguments of an instance.
struct LaunchOptionsEditor: View {

    @Binding var environment: [String: String]
    @Binding var arguments: [String]

    @State private var newName = ""
    @State private var newValue = ""
    @State private var newArgument = ""
    @State private var variableProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            environmentEditor
            argumentsEditor
        }
    }

    private var environmentEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Environment Variables")
                .font(.headline)

            ForEach(environment.keys.sorted(), id: \.self) { name in
                HStack {
                    Text("\(name)=\(environment[name] ?? "")")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    removeButton { environment.removeValue(forKey: name) }
                }
            }

            HStack {
                TextField("NAME", text: $newName)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 160)
                Text("=")
                TextField("value", text: $newValue)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(addVariable)
                Button("Add", action: addVariable)
                    .disabled(newName.isEmpty)
            }
            .textFieldStyle(.roundedBorder)

            if let variableProblem {
                Text(variableProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func addVariable() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if let problem = LaunchOptions.problem(withVariableName: name) {
            variableProblem = problem
            return
        }
        environment[name] = newValue
        newName = ""
        newValue = ""
        variableProblem = nil
    }

    private var argumentsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Command Line Arguments")
                .font(.headline)

            ForEach(Array(arguments.enumerated()), id: \.offset) { index, argument in
                HStack {
                    Text(argument)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    removeButton { arguments.remove(at: index) }
                }
            }

            HStack {
                TextField("--argument", text: $newArgument)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addArgument)
                Button("Add", action: addArgument)
                    .disabled(LaunchOptions.normalizedArgument(newArgument) == nil)
            }

            Text("One argument per entry. Spaces stay part of the argument.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addArgument() {
        guard let argument = LaunchOptions.normalizedArgument(newArgument) else { return }
        arguments.append(argument)
        newArgument = ""
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}
