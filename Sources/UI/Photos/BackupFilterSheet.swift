import SwiftUI
import Photos
import KatafractStyle

struct BackupFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var startDate: Date?
    @Binding var endDate: Date?
    @Binding var selectedMediaTypes: Set<String>

    @State private var isDateRangeEnabled = false
    @State private var tempStartDate = Date(timeIntervalSinceNow: -86400 * 365)
    @State private var tempEndDate = Date()

    let mediaTypes = [
        ("Photos", "photo"),
        ("Videos", "video"),
        ("Live Photos", "livephoto"),
        ("Screenshots", "screenshot"),
        ("Selfies", "selfie")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Date Range") {
                    Toggle("Filter by date", isOn: $isDateRangeEnabled)

                    if isDateRangeEnabled {
                        DatePicker(
                            "From",
                            selection: $tempStartDate,
                            displayedComponents: .date
                        )
                        DatePicker(
                            "To",
                            selection: $tempEndDate,
                            displayedComponents: .date
                        )
                        Button(role: .destructive) {
                            isDateRangeEnabled = false
                            startDate = nil
                            endDate = nil
                        } label: {
                            Text("Clear date filter")
                        }
                    }
                }

                Section("Media Type") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(mediaTypes, id: \.0) { label, value in
                            HStack {
                                Image(systemName: selectedMediaTypes.contains(value) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedMediaTypes.contains(value) ? .blue : .gray)
                                Text(label)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleMediaType(value)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if !selectedMediaTypes.isEmpty {
                        Button(role: .destructive) {
                            selectedMediaTypes.removeAll()
                        } label: {
                            Text("Clear media type filters")
                        }
                    }
                }

                Section {
                    HStack {
                        Text("All types selected")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if selectedMediaTypes.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .navigationTitle("Filter Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        if isDateRangeEnabled {
                            startDate = tempStartDate
                            endDate = tempEndDate
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            if let start = startDate, let end = endDate {
                isDateRangeEnabled = true
                tempStartDate = start
                tempEndDate = end
            }
        }
    }

    private func toggleMediaType(_ type: String) {
        if selectedMediaTypes.contains(type) {
            selectedMediaTypes.remove(type)
        } else {
            selectedMediaTypes.insert(type)
        }
    }
}

#Preview {
    @State var startDate: Date? = nil
    @State var endDate: Date? = nil
    @State var selectedTypes = Set<String>()

    return BackupFilterSheet(
        startDate: $startDate,
        endDate: $endDate,
        selectedMediaTypes: $selectedTypes
    )
}
