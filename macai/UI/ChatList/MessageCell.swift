//
//  MessageCell.swift
//  macai
//
//  Created by Renat Notfullin on 25.03.2023.
//

import SwiftUI

struct MessageCell: View, Equatable {
    static func == (lhs: MessageCell, rhs: MessageCell) -> Bool {
        lhs.chat.id == rhs.chat.id &&
        lhs.timestamp == rhs.timestamp &&
        lhs.message == rhs.message &&
        lhs.$isActive.wrappedValue == rhs.$isActive.wrappedValue &&
        lhs.searchText == rhs.searchText &&
        lhs.chat.isPinned == rhs.chat.isPinned
    }
    
    @ObservedObject var chat: ChatEntity
    @State var timestamp: Date
    var message: String
    @Binding var isActive: Bool
    let viewContext: NSManagedObjectContext
    @State private var isHovered = false
    @Environment(\.colorScheme) var colorScheme

    var searchText: String = ""
    
    private var filteredMessage: String {
        if !message.starts(with: "<think>") {
            return message
        }
        let messageWithoutNewlines = message.replacingOccurrences(of: "\n", with: " ")
        let messageWithoutThinking = messageWithoutNewlines.replacingOccurrences(
            of: "<think>.*?</think>",
            with: "",
            options: .regularExpression
        )
        return messageWithoutThinking.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Button {
            isActive = true
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    if let personaName = chat.persona?.name {
                        HighlightedText(personaName, highlight: searchText)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    else {
                        Text("No assistant selected")
                            .font(.caption)
                            .lineLimit(1)
                    }

                    if chat.name != "" {
                        HighlightedText(chat.name, highlight: searchText)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if filteredMessage != "" {
                        HighlightedText(filteredMessage, highlight: searchText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(8)
                Spacer()
                
                if chat.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundColor(self.isActive ? .white : .gray)
                        .font(.caption)
                        .padding(.trailing, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(self.isActive ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        self.isActive
                            ? Color.accentColor
                            : self.isHovered
                                ? (colorScheme == .dark ? Color(hex: "#666666")! : Color(hex: "#CCCCCC")!) : Color.clear
                    )
            )
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.borderless)
        .background(Color.clear)
    }
}

struct MessageCell_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MessageCell(
                chat: createPreviewChat(name: "Regular Chat"),
                timestamp: Date(),
                message: "Hello, how are you?",
                isActive: .constant(false),
                viewContext: PersistenceController.preview.container.viewContext
            )

            MessageCell(
                chat: createPreviewChat(name: "Selected Chat"),
                timestamp: Date(),
                message: "This is a selected chat preview",
                isActive: .constant(true),
                viewContext: PersistenceController.preview.container.viewContext
            )

            MessageCell(
                chat: createPreviewChat(name: "Long Message"),
                timestamp: Date(),
                message:
                    "This is a very long message that should be truncated when displayed in the preview cell of our chat application",
                isActive: .constant(false),
                viewContext: PersistenceController.preview.container.viewContext
            )
        }
        .previewLayout(.fixed(width: 300, height: 100))
    }

    static func createPreviewChat(name: String) -> ChatEntity {
        let context = PersistenceController.preview.container.viewContext
        let chat = ChatEntity(context: context)
        chat.id = UUID()
        chat.name = name
        chat.createdDate = Date()
        chat.updatedDate = Date()
        chat.systemMessage = AppConstants.chatGptSystemMessage
        chat.gptModel = AppConstants.chatGptDefaultModel
        return chat
    }
}
