//
//  ChatView.swift
//  macai
//
//  Created by Renat Notfullin on 18.03.2023.
//

import CoreData
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let viewContext: NSManagedObjectContext
    @State var chat: ChatEntity
    @State private var waitingForResponse = false
    @AppStorage("gptToken") var gptToken = ""
    @AppStorage("gptModel") var gptModel = AppConstants.chatGptDefaultModel
    @AppStorage("chatContext") var chatContext = AppConstants.chatGptContextSize
    @AppStorage("lastOpenedChatId") var lastOpenedChatId = ""
    @State var messageCount: Int = 0
    @State private var messageField = ""
    @State private var newMessage: String = ""
    @State private var editSystemMessage: Bool = false
    @State private var isStreaming: Bool = false
    @State private var isHovered = false
    @State private var currentStreamingMessage: String = ""
    @State private var attachedImages: [ImageAttachment] = []
    @StateObject private var store = ChatStore(persistenceController: PersistenceController.shared)
    @AppStorage("useChatGptForNames") var useChatGptForNames: Bool = false
    @AppStorage("useStream") var useStream: Bool = true
    @AppStorage("apiUrl") var apiUrl: String = AppConstants.apiUrlChatCompletions
    @StateObject private var chatViewModel: ChatViewModel
    @State private var renderTime: Double = 0
    @State private var selectedPersona: PersonaEntity?
    @State private var selectedApiService: APIServiceEntity?
    var backgroundColor = Color(NSColor.controlBackgroundColor)
    @State private var currentError: ErrorMessage?
    @Environment(\.colorScheme) private var colorScheme
    @State private var isBottomContainerExpanded = false
    @State private var codeBlocksRendered = false
    @State private var pendingCodeBlocks = 0
    @State private var userIsScrolling = false
    @State private var scrollDebounceWorkItem: DispatchWorkItem?

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \APIServiceEntity.addedDate, ascending: false)],
        animation: .default
    )
    private var apiServices: FetchedResults<APIServiceEntity>

    init(viewContext: NSManagedObjectContext, chat: ChatEntity) {
        self.viewContext = viewContext
        self._chat = State(initialValue: chat)

        self._chatViewModel = StateObject(
            wrappedValue: ChatViewModel(chat: chat, viewContext: viewContext)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ScrollViewReader { scrollView in
                    VStack {
                        SystemMessageBubbleView(
                            message: chat.systemMessage,
                            color: chat.persona?.color,
                            newMessage: $newMessage,
                            editSystemMessage: $editSystemMessage
                        )
                        .id("system_message")

                        if chat.messages.count > 0 {
                            ForEach(chatViewModel.sortedMessages, id: \.self) { messageEntity in
                                let bubbleContent = ChatBubbleContent(
                                    message: messageEntity.body,
                                    own: messageEntity.own,
                                    waitingForResponse: messageEntity.waitingForResponse,
                                    errorMessage: nil,
                                    systemMessage: false,
                                    isStreaming: isStreaming,
                                    isLatestMessage: messageEntity.id == chatViewModel.sortedMessages.last?.id
                                )
                                ChatBubbleView(content: bubbleContent, message: messageEntity)
                                    .id(messageEntity.id)
                            }
                        }

                        if chat.waitingForResponse {
                            let bubbleContent = ChatBubbleContent(
                                message: "",
                                own: false,
                                waitingForResponse: true,
                                errorMessage: nil,
                                systemMessage: false,
                                isStreaming: isStreaming,
                                isLatestMessage: false
                            )

                            ChatBubbleView(content: bubbleContent)
                                .id(-1)
                        }
                        else if let error = currentError {
                            let bubbleContent = ChatBubbleContent(
                                message: "",
                                own: false,
                                waitingForResponse: false,
                                errorMessage: error,
                                systemMessage: false,
                                isStreaming: isStreaming,
                                isLatestMessage: true
                            )

                            ChatBubbleView(content: bubbleContent)
                                .id(-2)
                        }
                    }
                    .padding(24)
                    .onAppear {
                        pendingCodeBlocks = chatViewModel.sortedMessages.reduce(0) { count, message in
                            count + (message.body.components(separatedBy: "```").count - 1) / 2
                        }

                        if let lastMessage = chatViewModel.sortedMessages.last {
                            scrollView.scrollTo(lastMessage.id, anchor: .bottom)
                        }

                        if pendingCodeBlocks == 0 {
                            codeBlocksRendered = true
                        }
                    }
                    .onSwipe { event in
                        switch event.direction {
                        case .up:
                            userIsScrolling = true
                        case .none:
                            break
                        case .down:
                            break
                        case .left:
                            break
                        case .right:
                            break
                        }
                    }
                    .onChange(of: chatViewModel.sortedMessages.last?.body) { _ in
                        if isStreaming && !userIsScrolling {
                            scrollDebounceWorkItem?.cancel()

                            let workItem = DispatchWorkItem {
                                if let lastMessage = chatViewModel.sortedMessages.last {
                                    withAnimation(.easeOut(duration: 1)) {
                                        scrollView.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }

                            scrollDebounceWorkItem = workItem
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
                        }
                    }
                    .onReceive([chat.messages.count].publisher) { newCount in
                        DispatchQueue.main.async {
                            if waitingForResponse || currentError != nil {
                                withAnimation {
                                    scrollView.scrollTo(-1)
                                }
                            }
                            else if newCount > self.messageCount {
                                self.messageCount = newCount

                                let sortedMessages = chatViewModel.sortedMessages
                                if let lastMessage = sortedMessages.last {
                                    scrollView.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RetryMessage"))) { _ in
                        guard !chat.waitingForResponse && !isStreaming else { return }

                        if currentError != nil {
                            sendMessage(ignoreMessageInput: true)
                        }
                        else {
                            if let lastUserMessage = chatViewModel.sortedMessages.last(where: { $0.own }) {
                                let messageToResend = lastUserMessage.body

                                if let lastMessage = chatViewModel.sortedMessages.last {
                                    viewContext.delete(lastMessage)
                                    if !lastMessage.own,
                                        let secondLastMessage = chatViewModel.sortedMessages.dropLast().last
                                    {
                                        viewContext.delete(secondLastMessage)
                                    }
                                    try? viewContext.save()
                                }

                                newMessage = messageToResend
                                sendMessage()
                            }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("IgnoreError"))) { _ in
                        currentError = nil
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CodeBlockRendered"))) {
                        _ in
                        if pendingCodeBlocks > 0 {
                            pendingCodeBlocks -= 1
                            if pendingCodeBlocks == 0 {
                                codeBlocksRendered = true
                                if let lastMessage = chatViewModel.sortedMessages.last {
                                    scrollView.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }

                .id("chatContainer")
            }
            .modifier(MeasureModifier(renderTime: $renderTime))
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        .clear,
                        backgroundColor.opacity(0.25),
                        backgroundColor.opacity(0.5),
                        backgroundColor.opacity(0.9),
                        backgroundColor,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 40)
                .padding(.trailing, 16)
                .allowsHitTesting(false)
            }

            ChatBottomContainerView(
                chat: chat,
                newMessage: $newMessage,
                isExpanded: $isBottomContainerExpanded,
                attachedImages: $attachedImages,
                imageUploadsAllowed: chat.apiService?.imageUploadsAllowed ?? false,
                onSendMessage: {
                    if editSystemMessage {
                        chat.systemMessage = newMessage
                        newMessage = ""
                        editSystemMessage = false
                        store.saveInCoreData()
                    }
                    else if newMessage != "" && newMessage != " " {
                        self.sendMessage()
                    }
                },
                onAddImage: {
                    selectAndAddImages()
                }
            )

        }
        .background(backgroundColor)
        .navigationTitle(
            chat.name != "" ? chat.name : chat.persona?.name ?? "macai LLM chat"
        )
        .onAppear(perform: {
            self.lastOpenedChatId = chat.id.uuidString
            print("lastOpenedChatId: \(lastOpenedChatId)")
            Self._printChanges()
            DispatchQueue.main.asyncAfter(deadline: .now()) {
                let startTime = CFAbsoluteTimeGetCurrent()
                _ = self.body
                renderTime = CFAbsoluteTimeGetCurrent() - startTime
            }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecreateMessageManager"))) {
            notification in
            if let chatId = notification.userInfo?["chatId"] as? UUID,
                chatId == chat.id
            {
                print("RecreateMessageManager notification received for chat \(chatId)")
                chatViewModel.recreateMessageManager()
            }
        }

    }
}

extension ChatView {
    func sendMessage(ignoreMessageInput: Bool = false) {
        guard chatViewModel.canSendMessage else {
            currentError = ErrorMessage(
                type: .noApiService("No API service selected. Select the API service to send your first message"),
                timestamp: Date()
            )
            return
        }

        resetError()

        var messageContents: [MessageContent] = []
        let messageText = newMessage

        if !messageText.isEmpty {
            messageContents.append(MessageContent(text: messageText))
        }

        for attachment in attachedImages {
            if attachment.imageEntity == nil {
                attachment.saveToEntity(context: viewContext)
            }

            messageContents.append(MessageContent(imageAttachment: attachment))
        }

        let messageBody: String
        let hasImages = !attachedImages.isEmpty

        if hasImages {
            messageBody = messageContents.toString()
        }
        else {
            messageBody = messageText
        }

        let isFirstMessage = chat.messages.count == 0

        if !ignoreMessageInput {
            saveNewMessageInStore(with: messageBody)

            attachedImages = []

            if isFirstMessage {
                withAnimation {
                    isBottomContainerExpanded = false
                }
            }
        }

        userIsScrolling = false

        if chat.apiService?.useStreamResponse ?? false {
            self.isStreaming = true
            chatViewModel.sendMessageStream(
                messageBody,
                contextSize: Int(chat.apiService?.contextSize ?? Int16(AppConstants.chatGptContextSize))
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        handleResponseFinished()
                        chatViewModel.generateChatNameIfNeeded()
                        break
                    case .failure(let error):
                        print("Error sending message: \(error)")
                        currentError = ErrorMessage(type: error as! APIError, timestamp: Date())
                        handleResponseFinished()
                    }
                }
            }
        }
        else {
            self.waitingForResponse = true
            chatViewModel.sendMessage(
                messageBody,
                contextSize: Int(chat.apiService?.contextSize ?? Int16(AppConstants.chatGptContextSize))
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        chatViewModel.generateChatNameIfNeeded()
                        handleResponseFinished()
                        break
                    case .failure(let error):
                        print("Error sending message: \(error)")
                        currentError = ErrorMessage(type: error as! APIError, timestamp: Date())
                        handleResponseFinished()
                    }
                }
            }
        }
    }

    private func saveNewMessageInStore(with messageBody: String) {
        let newMessageEntity = MessageEntity(context: viewContext)
        newMessageEntity.id = Int64(chat.messages.count + 1)
        newMessageEntity.body = messageBody
        newMessageEntity.timestamp = Date()
        newMessageEntity.own = true
        newMessageEntity.chat = chat

        chat.updatedDate = Date()
        chat.addToMessages(newMessageEntity)
        chat.objectWillChange.send()

        newMessage = ""
    }

    private func selectAndAddImages() {
        guard chat.apiService?.imageUploadsAllowed == true else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .heic, .heif, UTType(filenameExtension: "webp")].compactMap { $0 }
        panel.title = "Select Images"
        panel.message = "Choose images to upload"

        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    let attachment = ImageAttachment(url: url, context: self.viewContext)
                    DispatchQueue.main.async {
                        withAnimation {
                            self.attachedImages.append(attachment)
                        }
                    }
                }
            }
        }
    }

    private func handleResponseFinished() {
        self.isStreaming = false
        chat.waitingForResponse = false
        userIsScrolling = false
    }

    private func resetError() {
        currentError = nil
    }
}

struct MeasureModifier: ViewModifier {
    @Binding var renderTime: Double

    func body(content: Content) -> some View {
        content
            .onAppear {
                let start = DispatchTime.now()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let end = DispatchTime.now()
                    let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
                    let timeInterval = Double(nanoTime) / 1_000_000  // Convert to milliseconds
                    renderTime = timeInterval
                    print("Render time: \(timeInterval) ms")
                }
            }
    }
}
