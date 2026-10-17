import SwiftUI

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("URL", text: $session.serverURL)
                        .textContentType(.URL)
                        #if os(iOS)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    TextField("Dev user (until sign-in exists)", text: $session.devUser)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                }
                Section("About") {
                    LabeledContent("Build", value: Session.buildInfo)
                    LabeledContent("Device id", value: session.deviceId)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 240)
        #endif
    }
}
