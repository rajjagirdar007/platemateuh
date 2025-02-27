import SwiftUI
import AVFoundation
import Speech
import Combine
import CoreLocation
import GoogleGenerativeAI

// MARK: - App Entry Point
@main
struct RestaurantAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Constants
struct Constants {
    // API key should be provided through environment variables
    static var geminiAPIKey: String {
        guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] else {
            print("Warning: GEMINI_API_KEY not found in environment variables.")
            return "YOUR_API_KEY" // Fallback key, ideally this should be replaced
        }
        return apiKey
    }
    static let modelName = "gemini-2.0-flash-thinking-exp-01-21" // Using a more reliable model
}

// MARK: - Location Service
class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    @Published var currentLocation: CLLocation?
    @Published var locationStatus: CLAuthorizationStatus?
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        locationStatus = status
        if status == .authorizedWhenInUse {
            locationManager.startUpdatingLocation()
        }
    }
}

// MARK: - Gemini API Manager
class GeminiWebSocketManager: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var isListening = false
    
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private let audioSession = AVAudioSession.sharedInstance()
    
    var locationText: String = "nearby"
    
    // Gemini API properties
    private var model: GenerativeModel?
    private var chat: Chat?
    
    func connect() {
        isConnecting = true
        
        // Initialize the Gemini model
        let config = GenerationConfig(
            temperature: 0.7,
            topP: 0.95,
            topK: 64,
            maxOutputTokens: 2048,
            responseMIMEType: "text/plain"
        )
        
        model = GenerativeModel(
            name: Constants.modelName,
            apiKey: Constants.geminiAPIKey,
            generationConfig: config
        )
        
        // Initialize the chat
        chat = model?.startChat(history: [])
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isConnected = true
            self.isConnecting = false
            
            // Add system message
            self.addMessage(ChatMessage(text: "Hello! I'm your restaurant assistant. I can help you find restaurants in your area. What type of food are you looking for?", isUser: false))
        }
    }
    
    func disconnect() {
        isConnected = false
        stopListening()
        model = nil
        chat = nil
    }
    
    func sendTextMessage(_ text: String) {
        let userMessage = ChatMessage(text: text, isUser: true)
        addMessage(userMessage)
        
        // Create message with location context
        let messageWithLocation = "Based on my location (\(locationText)), \(text)"
        
        // Send message to Gemini API
        sendMessageToGeminiAPI(messageWithLocation)
    }
    
    private func sendMessageToGeminiAPI(_ message: String) {
        guard let chat = chat else {
            print("Chat not initialized")
            return
        }
        
        Task {
            do {
                // Show typing indicator or some loading state here
                let response = try await chat.sendMessage(message)
                
                // Process the response on the main thread
                DispatchQueue.main.async {
                    if let responseText = response.text {
                        self.addMessage(ChatMessage(text: responseText, isUser: false))
                    } else {
                        self.addMessage(ChatMessage(text: "I couldn't find that information. Can you try asking in a different way?", isUser: false))
                    }
                }
            } catch {
                print("Error from Gemini API: \(error)")
                
                // Handle error on the main thread
                DispatchQueue.main.async {
                    self.addMessage(ChatMessage(text: "Sorry, I encountered an error. Please try again.", isUser: false))
                }
            }
        }
    }
    
    private func addMessage(_ message: ChatMessage) {
        DispatchQueue.main.async {
            self.messages.append(message)
        }
    }
    
    // MARK: - Speech Recognition
    
    func startListening() {
        guard !isListening else { return }
        
        // Request permission
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self, status == .authorized else { return }
            
            do {
                try self.startRecording()
                self.isListening = true
            } catch {
                print("Recording failed: \(error)")
            }
        }
    }
    
    private func startRecording() throws {
        // Cancel any previous tasks
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Configure audio session
        try audioSession.setCategory(.record, mode: .default)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        // Setup audio engine input
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        recognitionRequest?.shouldReportPartialResults = true
        
        // Create recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) { [weak self] result, error in
            guard let self = self else { return }
            
            var isFinal = false
            
            if let result = result {
                // Use the best transcription
                let transcription = result.bestTranscription.formattedString
                isFinal = result.isFinal
                
                // If final, send the message
                if isFinal {
                    self.sendTextMessage(transcription)
                    self.stopListening()
                }
            }
            
            if error != nil || isFinal {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                
                self.recognitionRequest = nil
                self.recognitionTask = nil
                
                self.isListening = false
            }
        }
        
        // Configure the microphone input
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
    }
    
    func stopListening() {
        if isListening {
            audioEngine.stop()
            recognitionRequest?.endAudio()
            isListening = false
            
            // Reset audio session
            do {
                try audioSession.setActive(false)
            } catch {
                print("Error stopping audio session: \(error)")
            }
        }
    }
    
    // Update location text based on actual coordinates
    func updateLocationText(latitude: Double, longitude: Double) {
        self.locationText = "latitude \(latitude), longitude \(longitude)"
    }
}

// MARK: - Models
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    let isUser: Bool
    let timestamp = Date()
    
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.isUser == rhs.isUser
    }
}

// MARK: - Setup Instructions
/*
 To use this app with the Gemini API:
 
 1. Install the GoogleGenerativeAI dependency:
    - Using Swift Package Manager, add: https://github.com/google/generative-ai-swift
    
 2. Configure Environment Variables:
    - In Xcode, go to your target's scheme
    - Edit Scheme > Run > Arguments > Environment Variables
    - Add GEMINI_API_KEY with your actual API key
    
 3. Add the required Info.plist entries:
    <key>NSMicrophoneUsageDescription</key>
    <string>This app uses the microphone to record your voice for restaurant recommendations.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>This app uses speech recognition to understand your restaurant queries.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>This app uses your location to find restaurants near you.</string>
 */

// MARK: - Views
struct ContentView: View {
    @StateObject private var webSocketManager = GeminiWebSocketManager()
    @StateObject private var locationService = LocationService()
    
    @State private var userInput = ""
    @State private var showingSettings = false
    
    var body: some View {
        NavigationView {
            VStack {
                if webSocketManager.isConnected {
                    ChatView(messages: webSocketManager.messages)
                    
                    HStack {
                        // Microphone Button
                        Button(action: {
                            if webSocketManager.isListening {
                                webSocketManager.stopListening()
                            } else {
                                webSocketManager.startListening()
                            }
                        }) {
                            Image(systemName: webSocketManager.isListening ? "mic.fill" : "mic")
                                .font(.system(size: 20))
                                .foregroundColor(webSocketManager.isListening ? .red : .blue)
                                .padding()
                                .background(Circle().fill(Color.gray.opacity(0.2)))
                        }
                        
                        // Text Input Field
                        TextField("Type your message...", text: $userInput)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 20).fill(Color.gray.opacity(0.2)))
                            .disabled(webSocketManager.isListening)
                        
                        // Send Button
                        Button(action: {
                            if !userInput.isEmpty {
                                webSocketManager.sendTextMessage(userInput)
                                userInput = ""
                            }
                        }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.blue)
                        }
                        .disabled(userInput.isEmpty)
                    }
                    .padding()
                } else {
                    ConnectionView(
                        isConnecting: webSocketManager.isConnecting,
                        connect: {
                            webSocketManager.connect()
                        }
                    )
                }
            }
            .navigationTitle("Restaurant Assistant")
            .navigationBarItems(trailing: Button(action: {
                showingSettings = true
            }) {
                Image(systemName: "gear")
            })
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .onAppear {
                requestPermissions()
            }
            .onChange(of: locationService.currentLocation) { oldLocation, newLocation in
                if let location = newLocation {
                    webSocketManager.updateLocationText(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    )
                }
            }
        }
    }
    
    private func requestPermissions() {
        // Request microphone permission
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        
        // Speech recognition permission is requested when needed
    }
}

struct ChatView: View {
    let messages: [ChatMessage]
    
    var body: some View {
        ScrollViewReader { scrollView in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { oldCount, newCount in
                if let lastMessage = messages.last {
                    withAnimation {
                        scrollView.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
                Text(message.text)
                    .padding(12)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.leading, 60)
            } else {
                Text(message.text)
                    .padding(12)
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.trailing, 60)
                Spacer()
            }
        }
    }
}

struct ConnectionView: View {
    let isConnecting: Bool
    let connect: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 80))
                .foregroundColor(.blue)
            
            Text("Restaurant Assistant")
                .font(.largeTitle)
                .bold()
            
            Text("Find the perfect restaurant with your voice assistant")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .foregroundColor(.secondary)
            
            if isConnecting {
                ProgressView()
                    .padding()
                Text("Connecting...")
                    .foregroundColor(.secondary)
            } else {
                Button(action: connect) {
                    Text("Connect")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(width: 200)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding()
    }
}

struct SettingsView: View {
    @State private var apiKey: String = Constants.geminiAPIKey
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("API Settings")) {
                    SecureField("API Key", text: $apiKey)
                        .disabled(true)
                        .foregroundColor(.secondary)
                    
                    Text("Model: \(Constants.modelName)")
                        .foregroundColor(.secondary)
                    
                    Text("Note: To change the API key, edit the environment variable in Xcode scheme.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("About")) {
                    Text("Restaurant Assistant App")
                        .foregroundColor(.secondary)
                    
                    Text("Version 1.0")
                        .foregroundColor(.secondary)
                    
                    Text("Using Google Generative AI")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Info.plist Requirements
/*
Add these to your Info.plist:

<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to record your voice for restaurant recommendations.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>This app uses speech recognition to understand your restaurant queries.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app uses your location to find restaurants near you.</string>
*/
