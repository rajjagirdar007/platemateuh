import SwiftUI
import AVFoundation
import Speech
import Combine
import CoreLocation
import GoogleGenerativeAI
import MapKit

// MARK: - App Entry Point
@main
struct RestaurantAssistantApp: App {
    @StateObject private var dataStore = DataStore()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataStore)
                .preferredColorScheme(.light) // Default to light mode, respects system settings
        }
    }
}

// MARK: - Constants and Config
struct AppConfig {
    // API key should be provided through environment variables
    static var geminiAPIKey: String {
        guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] else {
            print("Warning: GEMINI_API_KEY not found in environment variables.")
            return "YOUR_API_KEY" // Fallback key, ideally this should be replaced
        }
        return apiKey
    }
    static let modelName = "gemini-2.0-flash-thinking-exp-01-21"
    
    // App appearance
    struct UI {
        static let primaryColor = Color.blue
        static let accentColor = Color.orange
        static let backgroundColor = Color(UIColor.systemBackground)
        static let secondaryBackgroundColor = Color(UIColor.secondarySystemBackground)
        static let textColor = Color(UIColor.label)
        static let secondaryTextColor = Color(UIColor.secondaryLabel)
        static let userBubbleColor = Color.blue
        static let assistantBubbleColor = Color(UIColor.systemGray5)
        static let cornerRadius: CGFloat = 16
        static let standardPadding: CGFloat = 16
        static let bubblePadding: CGFloat = 12
        static let iconSize: CGFloat = 22
        static let animationDuration: Double = 0.3
    }
    
    // Feature flags
    struct Features {
        static let enableVoiceInput = true
        static let enableMapView = true
        static let enableFavorites = true
        static let enableFilters = true
        static let enableSharing = true
        static let enableReservations = true
        static let maxRecentSearches = 10
    }
}

// MARK: - Data Models

// Restaurant Model
struct Restaurant: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let address: String
    let phoneNumber: String?
    let website: String?
    let rating: Double
    let priceLevel: Int // 1-4 ($-$$$$)
    let cuisine: [String]
    let coordinates: CLLocationCoordinate2D
    let imageURL: String?
    let hours: [String]?
    let description: String?
    var distance: Double? // in meters
    
    static func == (lhs: Restaurant, rhs: Restaurant) -> Bool {
        lhs.id == rhs.id
    }
    
    // Example restaurant for previews
    static var example: Restaurant {
        Restaurant(
            id: "123",
            name: "Italian Delight",
            address: "123 Main St, City",
            phoneNumber: "(555) 123-4567",
            website: "https://italiandelight.example.com",
            rating: 4.5,
            priceLevel: 2,
            cuisine: ["Italian", "Pizza", "Pasta"],
            coordinates: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            imageURL: "https://example.com/image.jpg",
            hours: ["Mon-Fri: 11:00 AM - 10:00 PM", "Sat-Sun: 10:00 AM - 11:00 PM"],
            description: "Authentic Italian cuisine with homemade pasta and brick oven pizza.",
            distance: 1200
        )
    }
}

// For compatibility with Codable
extension CLLocationCoordinate2D: Codable {
    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        self.init(latitude: latitude, longitude: longitude)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
    }
}

// Chat message model
struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    var text: String
    let isUser: Bool
    let timestamp: Date
    let containsRestaurants: Bool
    let restaurants: [Restaurant]
    let messageType: MessageType
    
    enum MessageType: String, Codable {
        case text
        case restaurantList
        case locationRequest
        case error
        case welcome
    }
    
    init(id: UUID = UUID(), text: String, isUser: Bool, timestamp: Date = Date(), containsRestaurants: Bool = false, restaurants: [Restaurant] = [], messageType: MessageType = .text) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.timestamp = timestamp
        self.containsRestaurants = containsRestaurants
        self.restaurants = restaurants
        self.messageType = messageType
    }
    
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// User preferences model
struct UserPreferences: Codable {
    var favoriteRestaurants: [String] // Restaurant IDs
    var dietaryPreferences: [String]
    var pricePreference: Int? // 1-4
    var cuisinePreferences: [String]
    var distancePreference: Double? // in meters
    var sortPreference: SortOption
    var recentSearches: [String]
    
    enum SortOption: String, Codable, CaseIterable {
        case distance = "Distance"
        case rating = "Rating"
        case price = "Price"
    }
    
    static var `default`: UserPreferences {
        UserPreferences(
            favoriteRestaurants: [],
            dietaryPreferences: [],
            pricePreference: nil,
            cuisinePreferences: [],
            distancePreference: 5000, // 5km default
            sortPreference: .distance,
            recentSearches: []
        )
    }
}

// MARK: - Data Store (Persistence)
class DataStore: ObservableObject {
    @Published var chatHistory: [ChatMessage] = []
    @Published var userPreferences: UserPreferences = .default
    @Published var favoriteRestaurants: [Restaurant] = []
    @Published var recentSearches: [String] = []
    
    private let chatHistoryKey = "chatHistory"
    private let userPreferencesKey = "userPreferences"
    private let favoriteRestaurantsKey = "favoriteRestaurants"
    
    init() {
        loadData()
    }
    
    func loadData() {
        // Load chat history
        if let data = UserDefaults.standard.data(forKey: chatHistoryKey),
           let decodedChatHistory = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            // Only keep the last 50 messages to avoid excessive memory usage
            self.chatHistory = Array(decodedChatHistory.suffix(50))
        }
        
        // Load user preferences
        if let data = UserDefaults.standard.data(forKey: userPreferencesKey),
           let decodedPreferences = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            self.userPreferences = decodedPreferences
            self.recentSearches = decodedPreferences.recentSearches
        }
        
        // Load favorite restaurants
        if let data = UserDefaults.standard.data(forKey: favoriteRestaurantsKey),
           let decodedFavorites = try? JSONDecoder().decode([Restaurant].self, from: data) {
            self.favoriteRestaurants = decodedFavorites
        }
    }
    
    func saveData() {
        // Save chat history
        if let encodedData = try? JSONEncoder().encode(chatHistory) {
            UserDefaults.standard.set(encodedData, forKey: chatHistoryKey)
        }
        
        // Save user preferences
        userPreferences.recentSearches = recentSearches
        if let encodedData = try? JSONEncoder().encode(userPreferences) {
            UserDefaults.standard.set(encodedData, forKey: userPreferencesKey)
        }
        
        // Save favorite restaurants
        if let encodedData = try? JSONEncoder().encode(favoriteRestaurants) {
            UserDefaults.standard.set(encodedData, forKey: favoriteRestaurantsKey)
        }
    }
    
    func addMessage(_ message: ChatMessage) {
        chatHistory.append(message)
        saveData()
    }
    
    func clearChatHistory() {
        chatHistory.removeAll()
        saveData()
    }
    
    func toggleFavorite(restaurant: Restaurant) {
        if let index = favoriteRestaurants.firstIndex(where: { $0.id == restaurant.id }) {
            favoriteRestaurants.remove(at: index)
            if let prefIndex = userPreferences.favoriteRestaurants.firstIndex(of: restaurant.id) {
                userPreferences.favoriteRestaurants.remove(at: prefIndex)
            }
        } else {
            favoriteRestaurants.append(restaurant)
            userPreferences.favoriteRestaurants.append(restaurant.id)
        }
        saveData()
    }
    
    func isFavorite(restaurant: Restaurant) -> Bool {
        favoriteRestaurants.contains(where: { $0.id == restaurant.id })
    }
    
    func addRecentSearch(_ search: String) {
        // Remove if exists already
        recentSearches.removeAll(where: { $0 == search })
        
        // Add to the beginning
        recentSearches.insert(search, at: 0)
        
        // Limit to max recent searches
        if recentSearches.count > AppConfig.Features.maxRecentSearches {
            recentSearches = Array(recentSearches.prefix(AppConfig.Features.maxRecentSearches))
        }
        
        saveData()
    }
}

// MARK: - Location Service
class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    @Published var currentLocation: CLLocation?
    @Published var locationStatus: CLAuthorizationStatus?
    @Published var isLocationAvailable = false
    @Published var userLocationName: String = "Current Location"
    @Published var isResolving = false
    
    // For map integration
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    
    override init() {
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
        self.locationStatus = locationManager.authorizationStatus
        
        print("LocationService initialized with status: \(String(describing: self.locationStatus?.rawValue))")
    }
    
    func requestLocationPermission() {
        print("Requesting location permission...")
        locationManager.requestWhenInUseAuthorization()
    }
    
    func startLocationUpdates() {
        print("Starting location updates...")
        locationManager.startUpdatingLocation()
    }
    
    func requestLocation() {
        print("Requesting one-time location...")
        locationManager.requestLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            print("Location update received but no valid location found")
            return
        }
        
        print("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        DispatchQueue.main.async {
            self.currentLocation = location
            self.isLocationAvailable = true
            
            // Update map region
            self.region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
            
            // Reverse geocode to get location name
            self.resolveLocationName(from: location)
        }
    }
    
    func resolveLocationName(from location: CLLocation) {
        guard !isResolving else { return }
        
        isResolving = true
        let geocoder = CLGeocoder()
        
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isResolving = false
                
                if let error = error {
                    print("Reverse geocoding error: \(error.localizedDescription)")
                    return
                }
                
                if let placemark = placemarks?.first {
                    var locationName = "Current Location"
                    
                    if let neighborhood = placemark.subLocality {
                        locationName = neighborhood
                    } else if let city = placemark.locality {
                        locationName = city
                    }
                    
                    self.userLocationName = locationName
                }
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed with error: \(error.localizedDescription)")
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        print("Location authorization changed to: \(status.rawValue)")
        
        DispatchQueue.main.async {
            self.locationStatus = status
        }
        
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            print("Location permission granted, starting updates")
            locationManager.startUpdatingLocation()
            // Also request a one-time location update immediately
            locationManager.requestLocation()
        case .denied, .restricted:
            print("Location permission denied")
        case .notDetermined:
            print("Location permission not determined")
        @unknown default:
            print("Unknown location authorization status")
        }
    }
    
    // Calculate distance between user and restaurant
    func distanceTo(restaurant: Restaurant) -> Double? {
        guard let currentLocation = currentLocation else { return nil }
        
        let restaurantLocation = CLLocation(
            latitude: restaurant.coordinates.latitude,
            longitude: restaurant.coordinates.longitude
        )
        
        return currentLocation.distance(from: restaurantLocation)
    }
}

// MARK: - View Models

// Main ViewModel for the assistant
class AssistantViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var isListening = false
    @Published var userInput = ""
    @Published var isProcessing = false
    @Published var showLocationRequestAlert = false
    @Published var selectedRestaurant: Restaurant?
    @Published var displayedRestaurants: [Restaurant] = []
    @Published var searchQuery = ""
    @Published var activeFilters: Set<String> = []
    @Published var showFilters = false
    @Published var sortOption: UserPreferences.SortOption = .distance
    
    // Flag to track if system prompt was sent
    private var systemPromptSent = false
    
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioSession = AVAudioSession.sharedInstance()
    
    // Dependencies
    private var locationService: LocationService
    private var dataStore: DataStore
    private var model: GenerativeModel?
    private var chat: Chat?
    
    // For partial speech recognition results
    @Published var currentTranscription = ""
    
    // Prompt engineering for better restaurant responses
    private let systemPrompt = """
    You are a helpful restaurant assistant. When the user asks about restaurants, return structured data for each restaurant that includes:
    1. Name
    2. Address
    3. Rating (1-5 stars)
    4. Price level (1-4, with 1 being least expensive)
    5. Cuisine type
    6. A brief description
    7. Phone number if available
    8. Website if available
    9. Opening hours if available
    
    Format your response with clear headers for each restaurant. First provide a brief, natural conversational introduction, then list 3-5 restaurant options that match the user's query, then end with a friendly question about whether they'd like more options or information about any specific restaurant.
    
    When asked for more details about a specific restaurant, provide an in-depth description including ambiance, popular dishes, and any special features.
    
    Use the user's location coordinates when provided to find truly nearby restaurants.
    """
    
    init(locationService: LocationService, dataStore: DataStore) {
        self.locationService = locationService
        self.dataStore = dataStore
        
        // Load messages from data store
        self.messages = dataStore.chatHistory
    }
    
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
            name: AppConfig.modelName,
            apiKey: AppConfig.geminiAPIKey,
            generationConfig: config
        )
        
        // Initialize the chat with system prompt
        // Note: The exact initialization depends on the specific version of the GoogleGenerativeAI SDK
        // Here's a more compatible approach
        let content = "\(systemPrompt)"
        
        chat = model?.startChat(history: [])
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isConnected = true
            self.isConnecting = false
            
            // Check if we need to add a welcome message
            if self.messages.isEmpty {
                // Add welcome message
                let welcomeMessage = ChatMessage(
                    text: "Hello! I'm your restaurant assistant. I can help you find great places to eat. What type of food are you looking for today?",
                    isUser: false,
                    messageType: .welcome
                )
                self.addMessage(welcomeMessage)
            }
        }
    }
    
    func disconnect() {
        isConnected = false
        stopListening()
        model = nil
        chat = nil
    }
    
    func sendTextMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // Add to recent searches
        dataStore.addRecentSearch(text)
        
        // Create and add user message
        let userMessage = ChatMessage(text: text, isUser: true)
        addMessage(userMessage)
        
        // Clear input
        userInput = ""
        
        // Show typing indicator
        isProcessing = true
        
        // Prepare location context for better results
        var messageWithLocation: String
        
        if let location = locationService.currentLocation {
            // We have coordinates, use them explicitly
            messageWithLocation = "Please find restaurants at these exact coordinates: \(location.coordinate.latitude), \(location.coordinate.longitude). The user is asking: \(text)"
        } else {
            // If we don't have coordinates yet, just use a general request
            messageWithLocation = "I am looking for restaurants nearby. \(text)"
            print("Warning: Using default 'nearby' for location as coordinates are not available")
            
            // Show location permission alert if not available
            if locationService.locationStatus == .denied || locationService.locationStatus == .restricted {
                showLocationRequestAlert = true
            }
        }
        
        print("Sending to Gemini: \(messageWithLocation)")
        
        // Send message to Gemini API
        sendMessageToGeminiAPI(messageWithLocation)
    }
    
    private func sendMessageToGeminiAPI(_ message: String) {
        guard let chat = chat else {
            print("Chat not initialized")
            isProcessing = false
            return
        }
        
        // First, send the system prompt if this is the first message
        if !systemPromptSent {
            Task {
                do {
                    print("Sending system prompt to Gemini API...")
                    try await chat.sendMessage(systemPrompt)
                    systemPromptSent = true
                    // Now send the actual message
                    self.sendActualMessage(message, chat: chat)
                } catch {
                    handleApiError(error)
                }
            }
        } else {
            // If system prompt already sent, just send the message
            sendActualMessage(message, chat: chat)
        }
    }
    
    private func sendActualMessage(_ message: String, chat: Chat) {
        Task {
            do {
                print("Sending message to Gemini API...")
                let response = try await chat.sendMessage(message)
                
                // Process the response on the main thread
                let responseText = response.text ?? "I couldn't find information about restaurants matching your request."
                print("Received response from Gemini")
                
                // Parse the response text for potential restaurant data
                let (extractedRestaurants, processedText) = extractRestaurantsFromText(responseText)
                
                DispatchQueue.main.async {
                    self.isProcessing = false
                    
                    let assistantMessage = ChatMessage(
                        text: processedText,
                        isUser: false,
                        containsRestaurants: !extractedRestaurants.isEmpty,
                        restaurants: extractedRestaurants,
                        messageType: !extractedRestaurants.isEmpty ? .restaurantList : .text
                    )
                    
                    self.addMessage(assistantMessage)
                    
                    // Update displayed restaurants if we extracted any
                    if !extractedRestaurants.isEmpty {
                        self.displayedRestaurants = extractedRestaurants
                    }
                }
            } catch {
                handleApiError(error)
            }
        }
    }
    
    private func handleApiError(_ error: Error) {
        print("Error from Gemini API: \(error)")
        
        // Handle error on the main thread
        DispatchQueue.main.async {
            self.isProcessing = false
            self.addMessage(ChatMessage(
                text: "Sorry, I encountered an error. Please try again.",
                isUser: false,
                messageType: .error
            ))
        }
        print("No text in response from Gemini")
        DispatchQueue.main.async {
            self.isProcessing = false
            self.addMessage(ChatMessage(
                text: "I couldn't find that information. Can you try asking in a different way?",
                isUser: false,
                messageType: .error
            ))
        }
    }

        
    // Function to extract restaurant info from AI response
    private func extractRestaurantsFromText(_ text: String) -> ([Restaurant], String) {
        // This is a simplified version - in a real app, you would use NLP or a more sophisticated
        // approach to extract structured data from the AI's response.
        // For this example, we'll create some mock restaurants based on keywords in the response.
        
        // Check if the text appears to contain restaurant recommendations
        let restaurantKeywords = ["restaurant", "café", "bistro", "diner", "eatery", "place", "bar", "grill"]
        let containsRestaurants = restaurantKeywords.contains { keyword in
            text.lowercased().contains(keyword.lowercased())
        }
        
        // If no restaurant keywords found, return original text with no restaurants
        if !containsRestaurants {
            return ([], text)
        }
        
        // For demo purposes, generate mock restaurants based on cuisine types found in text
        let cuisineTypes = ["Italian", "Chinese", "Mexican", "Indian", "Japanese", "Thai", "French", "American", "Mediterranean", "Greek"]
        var foundCuisines: [String] = []
        
        for cuisine in cuisineTypes {
            if text.lowercased().contains(cuisine.lowercased()) {
                foundCuisines.append(cuisine)
            }
        }
        
        // Generate mock restaurants based on found cuisines
        var restaurants: [Restaurant] = []
        let currentLocation = locationService.currentLocation
        
        for (index, cuisine) in foundCuisines.prefix(5).enumerated() {
            // Generate a somewhat random location near the user's location
            var restaurantCoordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
            
            if let location = currentLocation {
                // Create a location somewhat near the user (within ~1km)
                let latOffset = Double.random(in: -0.01...0.01)
                let lonOffset = Double.random(in: -0.01...0.01)
                restaurantCoordinate = CLLocationCoordinate2D(
                    latitude: location.coordinate.latitude + latOffset,
                    longitude: location.coordinate.longitude + lonOffset
                )
            }
            
            // Calculate mock distance
            var distance: Double? = nil
            if let location = currentLocation {
                let restaurantLocation = CLLocation(
                    latitude: restaurantCoordinate.latitude,
                    longitude: restaurantCoordinate.longitude
                )
                distance = location.distance(from: restaurantLocation)
            }
            
            // Create a mock restaurant
            let restaurant = Restaurant(
                id: "rest_\(UUID().uuidString)",
                name: "\(cuisine) \(["Delight", "Express", "Garden", "House", "Palace", "Bistro", "Kitchen"].randomElement()!)",
                address: "\(Int.random(in: 10...999)) \(["Main", "Oak", "Pine", "Maple", "Cedar"].randomElement()!) St",
                phoneNumber: "(555) \(Int.random(in: 100...999))-\(Int.random(in: 1000...9999))",
                website: "https://\(cuisine.lowercased())restaurant.example.com",
                rating: Double.random(in: 3.0...5.0).rounded(to: 1),
                priceLevel: Int.random(in: 1...4),
                cuisine: [cuisine],
                coordinates: restaurantCoordinate,
                imageURL: "https://example.com/\(cuisine)_\(index).jpg",
                hours: ["Mon-Fri: 11:00 AM - 10:00 PM", "Sat-Sun: 10:00 AM - 11:00 PM"],
                description: "Authentic \(cuisine) cuisine with a modern twist. Popular for their \(["signature dishes", "fresh ingredients", "vibrant atmosphere", "chef specials"].randomElement()!).",
                distance: distance
            )
            
            restaurants.append(restaurant)
        }
        
        return (restaurants, text)
    }
    
    private func addMessage(_ message: ChatMessage) {
        messages.append(message)
        dataStore.addMessage(message)
    }
    
    // MARK: - Voice Recognition
    
    func startListening() {
        guard !isListening else { return }
        
        // Request permission
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self, status == .authorized else { return }
            
            do {
                try self.startRecording()
                DispatchQueue.main.async {
                    self.isListening = true
                    self.currentTranscription = "Listening..."
                }
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
                // Use the best transcription for partial results
                let transcription = result.bestTranscription.formattedString
                isFinal = result.isFinal
                
                DispatchQueue.main.async {
                    if !isFinal {
                        self.currentTranscription = transcription
                    } else {
                        self.currentTranscription = ""
                        self.sendTextMessage(transcription)
                    }
                }
            }
            
            if error != nil || isFinal {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                
                self.recognitionRequest = nil
                self.recognitionTask = nil
                
                DispatchQueue.main.async {
                    self.isListening = false
                }
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
            currentTranscription = ""
            
            // Reset audio session
            do {
                try audioSession.setActive(false)
            } catch {
                print("Error stopping audio session: \(error)")
            }
        }
    }
    
    // MARK: - Restaurant Management
    
    func toggleFavorite(restaurant: Restaurant) {
        dataStore.toggleFavorite(restaurant: restaurant)
    }
    
    func isFavorite(restaurant: Restaurant) -> Bool {
        dataStore.isFavorite(restaurant: restaurant)
    }
    
    func getSuggestedQueries() -> [String] {
        // Combine recent searches and some suggested queries
        var suggestions = dataStore.recentSearches
        
        // Add some common restaurant queries if we don't have enough recent searches
        let commonQueries = [
            "Italian restaurants nearby",
            "Best sushi places",
            "Restaurants open now",
            "Outdoor dining options",
            "Family-friendly restaurants",
            "Vegan restaurants",
            "Restaurants with gluten-free options"
        ]
        
        // Add common queries that aren't already in suggestions
        for query in commonQueries {
            if !suggestions.contains(query) {
                suggestions.append(query)
            }
        }
        
        // Return a subset of suggestions
        return Array(suggestions.prefix(6))
    }
    
    func getAvailableCuisines() -> [String] {
        let cuisines = ["Italian", "Chinese", "Mexican", "Indian", "Japanese", "Thai",
                        "French", "American", "Mediterranean", "Greek", "Korean", "Vietnamese",
                        "Spanish", "Turkish", "Lebanese", "Ethiopian", "German", "Brazilian"]
        return cuisines
    }
    
    func filterRestaurants(query: String? = nil, cuisines: [String]? = nil, maxPrice: Int? = nil, minRating: Double? = nil) {
        // Start with all restaurants
        var filtered = displayedRestaurants
        
        // Filter by search query if provided
        if let query = query, !query.isEmpty {
            filtered = filtered.filter { restaurant in
                restaurant.name.lowercased().contains(query.lowercased()) ||
                restaurant.cuisine.contains { cuisine in
                    cuisine.lowercased().contains(query.lowercased())
                }
            }
        }
        
        // Filter by cuisines if provided
        if let cuisines = cuisines, !cuisines.isEmpty {
            filtered = filtered.filter { restaurant in
                restaurant.cuisine.contains { cuisine in
                    cuisines.contains(cuisine)
                }
            }
        }
        
        // Filter by price if provided
        if let maxPrice = maxPrice {
            filtered = filtered.filter { restaurant in
                restaurant.priceLevel <= maxPrice
            }
        }
        
        // Filter by rating if provided
        if let minRating = minRating {
            filtered = filtered.filter { restaurant in
                restaurant.rating >= minRating
            }
        }
        
        // Sort results
        switch sortOption {
        case .distance:
            filtered.sort { (a, b) -> Bool in
                guard let distanceA = a.distance, let distanceB = b.distance else {
                    return false
                }
                return distanceA < distanceB
            }
        case .rating:
            filtered.sort { $0.rating > $1.rating }
        case .price:
            filtered.sort { $0.priceLevel < $1.priceLevel }
        }
        
        // Update displayed restaurants
        displayedRestaurants = filtered
    }
    
    // Mock function to simulate making a reservation
    func makeReservation(restaurant: Restaurant, date: Date, partySize: Int) -> Bool {
        // In a real app, this would connect to a reservation API
        // For now, just simulate success with a high probability
        return Double.random(in: 0...1) < 0.9
    }
}

// MARK: - Views

// Main content view
struct ContentView: View {
    @StateObject private var viewModel = AssistantViewModel(
        locationService: LocationService(),
        dataStore: DataStore()
    )
    @StateObject private var locationService = LocationService()
    
    @State private var showSettings = false
    @State private var showingRestaurantDetail = false
    @State private var showMapView = false
    @State private var showFavorites = false
    @State private var locationRetryCount = 0
    @State private var showSuggestions = false
    
    @EnvironmentObject private var dataStore: DataStore
    
    var body: some View {
        ZStack {
            NavigationStack {
                VStack(spacing: 0) {
                    if viewModel.isConnected {
                        // Location indicator
                        LocationStatusBar(
                            isLocationAvailable: locationService.isLocationAvailable,
                            locationName: locationService.userLocationName,
                            retryAction: retryLocation
                        )
                        
                        // Chat interface
                        ChatView(viewModel: viewModel)
                            .environmentObject(locationService)
                        
                        // Input area
                        MessageInputView(
                            viewModel: viewModel,
                            showSuggestions: $showSuggestions
                        )
                        .padding(.top, 8)
                    } else {
                        WelcomeView(
                            isConnecting: viewModel.isConnecting,
                            connect: {
                                viewModel.connect()
                            }
                        )
                    }
                }
                .navigationTitle("Food Finder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: {
                            showFavorites.toggle()
                        }) {
                            Image(systemName: "heart")
                                .foregroundColor(AppConfig.UI.accentColor)
                        }
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            showMapView.toggle()
                        }) {
                            Image(systemName: "map")
                                .foregroundColor(AppConfig.UI.primaryColor)
                        }
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            showSettings.toggle()
                        }) {
                            Image(systemName: "gear")
                                .foregroundColor(AppConfig.UI.primaryColor)
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                        .environmentObject(viewModel)
                        .environmentObject(dataStore)
                }
                .sheet(isPresented: $showFavorites) {
                    FavoritesView()
                        .environmentObject(dataStore)
                        .environmentObject(viewModel)
                }
                .sheet(isPresented: $showMapView) {
                    MapView(restaurants: viewModel.displayedRestaurants)
                        .environmentObject(locationService)
                        .environmentObject(viewModel)
                }
                .sheet(isPresented: $showingRestaurantDetail) {
                    if let restaurant = viewModel.selectedRestaurant {
                        RestaurantDetailView(restaurant: restaurant)
                            .environmentObject(dataStore)
                            .environmentObject(viewModel)
                    }
                }
                .alert("Location Services Disabled", isPresented: $viewModel.showLocationRequestAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } message: {
                    Text("Location access is required for restaurant recommendations near you. Please enable it in Settings.")
                }
            }
            
            // Processing indicator
            if viewModel.isProcessing {
                LoadingView()
            }
        }
        .onAppear {
            initializeApp()
        }
        .onChange(of: locationService.currentLocation) { oldLocation, newLocation in
            if let location = newLocation {
                viewModel.displayedRestaurants = viewModel.displayedRestaurants.map { restaurant in
                    var updatedRestaurant = restaurant
                    let restaurantLocation = CLLocation(
                        latitude: restaurant.coordinates.latitude,
                        longitude: restaurant.coordinates.longitude
                    )
                    updatedRestaurant.distance = location.distance(from: restaurantLocation)
                    return updatedRestaurant
                }
            }
        }
        .onChange(of: viewModel.selectedRestaurant) { _, newRestaurant in
            if newRestaurant != nil {
                showingRestaurantDetail = true
            }
        }
    }
    
    private func initializeApp() {
        print("App appearing - initializing...")
        requestPermissions()
        
        // Request location immediately and start a retry timer
        locationService.requestLocationPermission()
        
        // Schedule location retries
        scheduleLocationRetry(delay: 2)
        
        // Initialize the viewModel
        if !viewModel.isConnected && !viewModel.isConnecting {
            viewModel.connect()
        }
    }
    
    private func requestPermissions() {
        // Request microphone permission
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            print("Microphone permission granted: \(granted)")
        }
        
        // Location permission is requested in the LocationService
    }
    
    private func scheduleLocationRetry(delay: Double) {
        // Only retry a few times to avoid excessive retries
        guard locationRetryCount < 5 else {
            print("Maximum location retry count reached")
            return
        }
        
        print("Scheduling location retry #\(locationRetryCount + 1) in \(delay) seconds")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.locationService.currentLocation == nil {
                print("Location still nil, retrying...")
                self.locationRetryCount += 1
                self.retryLocation()
                
                // Schedule another retry with exponential backoff
                self.scheduleLocationRetry(delay: min(delay * 2, 30))
            }
        }
    }
    
    private func retryLocation() {
        print("Manually retrying location...")
        
        // First check the authorization status
        if let status = locationService.locationStatus {
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                locationService.startLocationUpdates()
                locationService.requestLocation()
            case .notDetermined:
                locationService.requestLocationPermission()
            case .denied, .restricted:
                print("Location permission denied - cannot retry")
                // Show a notification to the user
                viewModel.showLocationRequestAlert = true
            @unknown default:
                print("Unknown location status")
            }
        } else {
            // If status is nil, try requesting permission
            locationService.requestLocationPermission()
        }
    }
}

// Location status bar
struct LocationStatusBar: View {
    let isLocationAvailable: Bool
    let locationName: String
    let retryAction: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: isLocationAvailable ? "location.fill" : "location.slash")
                .foregroundColor(isLocationAvailable ? .green : .red)
                .font(.system(size: 12))
            
            Text(isLocationAvailable ? locationName : "Location unavailable")
                .font(.caption)
                .foregroundColor(.secondary)
                
            if !isLocationAvailable {
                Button(action: retryAction) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(AppConfig.UI.secondaryBackgroundColor)
    }
}

// Chat view with messages
struct ChatView: View {
    @ObservedObject var viewModel: AssistantViewModel
    @EnvironmentObject var locationService: LocationService
    
    var body: some View {
        ScrollViewReader { scrollView in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageView(message: message, viewModel: viewModel)
                            .id(message.id)
                    }
                    
                    // Show partial transcription when listening
                    if viewModel.isListening && !viewModel.currentTranscription.isEmpty {
                        HStack {
                            Spacer()
                            Text(viewModel.currentTranscription)
                                .padding(12)
                                .background(Color.gray.opacity(0.3))
                                .foregroundColor(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: AppConfig.UI.cornerRadius))
                                .padding(.leading, 60)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { oldCount, newCount in
                if let lastMessage = viewModel.messages.last {
                    withAnimation {
                        scrollView.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.currentTranscription) { _, _ in
                // Scroll to bottom when transcription changes
                if !viewModel.messages.isEmpty {
                    withAnimation {
                        scrollView.scrollTo(viewModel.messages.last!.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(AppConfig.UI.backgroundColor)
    }
}

// Message bubble view
struct MessageView: View {
    let message: ChatMessage
    @ObservedObject var viewModel: AssistantViewModel
    
    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
            // If it contains restaurants, show them in a special view
            if message.containsRestaurants {
                HStack {
                    if message.isUser {
                        Spacer()
                    }
                    
                    Text(message.text)
                        .padding(AppConfig.UI.bubblePadding)
                        .background(message.isUser ? AppConfig.UI.userBubbleColor : AppConfig.UI.assistantBubbleColor)
                        .foregroundColor(message.isUser ? .white : AppConfig.UI.textColor)
                        .clipShape(RoundedRectangle(cornerRadius: AppConfig.UI.cornerRadius))
                        .padding(message.isUser ? .leading : .trailing, 60)
                    
                    if !message.isUser {
                        Spacer()
                    }
                }
                
                RestaurantCarouselView(restaurants: message.restaurants, viewModel: viewModel)
            } else {
                // Regular message bubble
                HStack {
                    if message.isUser {
                        Spacer()
                    }
                    
                    Text(message.text)
                        .padding(AppConfig.UI.bubblePadding)
                        .background(message.isUser ? AppConfig.UI.userBubbleColor : AppConfig.UI.assistantBubbleColor)
                        .foregroundColor(message.isUser ? .white : AppConfig.UI.textColor)
                        .clipShape(RoundedRectangle(cornerRadius: AppConfig.UI.cornerRadius))
                        .padding(message.isUser ? .leading : .trailing, 60)
                    
                    if !message.isUser {
                        Spacer()
                    }
                }
            }
        }
    }
}

// Message input view
struct MessageInputView: View {
    @ObservedObject var viewModel: AssistantViewModel
    @Binding var showSuggestions: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            // Suggestions
            if showSuggestions && viewModel.userInput.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.getSuggestedQueries(), id: \.self) { suggestion in
                            Button(action: {
                                viewModel.sendTextMessage(suggestion)
                                showSuggestions = false
                            }) {
                                Text(suggestion)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(AppConfig.UI.secondaryBackgroundColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .foregroundColor(AppConfig.UI.textColor)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            
            HStack {
                // Microphone Button
                if AppConfig.Features.enableVoiceInput {
                    Button(action: {
                        if viewModel.isListening {
                            viewModel.stopListening()
                        } else {
                            viewModel.startListening()
                            // Hide suggestions when listening
                            showSuggestions = false
                        }
                    }) {
                        Image(systemName: viewModel.isListening ? "mic.fill" : "mic")
                            .font(.system(size: 20))
                            .foregroundColor(viewModel.isListening ? .red : AppConfig.UI.primaryColor)
                            .padding()
                            .background(Circle().fill(AppConfig.UI.secondaryBackgroundColor))
                    }
                }
                
                // Text Input Field
                HStack {
                    TextField("Ask about restaurants...", text: $viewModel.userInput, onEditingChanged: { editing in
                        showSuggestions = editing
                    })
                    .padding(10)
                    .disabled(viewModel.isListening)
                    
                    if !viewModel.userInput.isEmpty {
                        Button(action: {
                            viewModel.userInput = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 20).fill(AppConfig.UI.secondaryBackgroundColor))
                
                // Send Button
                Button(action: {
                    if !viewModel.userInput.isEmpty {
                        viewModel.sendTextMessage(viewModel.userInput)
                        showSuggestions = false
                    }
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(viewModel.userInput.isEmpty ? .gray : AppConfig.UI.primaryColor)
                }
                .disabled(viewModel.userInput.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color(UIColor.systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.gray.opacity(0.2)),
            alignment: .top
        )
    }
}

// Restaurant carousel view for displaying search results
struct RestaurantCarouselView: View {
    let restaurants: [Restaurant]
    @ObservedObject var viewModel: AssistantViewModel
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(restaurants) { restaurant in
                    RestaurantCardView(restaurant: restaurant)
                        .environmentObject(viewModel)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 180)
    }
}

// Restaurant card view for the carousel
struct RestaurantCardView: View {
    let restaurant: Restaurant
    @EnvironmentObject var viewModel: AssistantViewModel
    @EnvironmentObject var dataStore: DataStore
    
    var body: some View {
        Button(action: {
            viewModel.selectedRestaurant = restaurant
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(restaurant.name)
                        .font(.headline)
                        .foregroundColor(AppConfig.UI.textColor)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button(action: {
                        viewModel.toggleFavorite(restaurant: restaurant)
                    }) {
                        Image(systemName: viewModel.isFavorite(restaurant: restaurant) ? "heart.fill" : "heart")
                            .foregroundColor(AppConfig.UI.accentColor)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                
                Text(restaurant.cuisine.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundColor(AppConfig.UI.secondaryTextColor)
                    .lineLimit(1)
                
                HStack {
                    // Rating stars
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= Int(restaurant.rating) ? "star.fill" :
                                (star == Int(restaurant.rating) + 1 && restaurant.rating.truncatingRemainder(dividingBy: 1) >= 0.5 ? "star.leadinghalf.fill" : "star"))
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                        }
                    }
                    
                    Text(String(format: "%.1f", restaurant.rating))
                        .font(.caption)
                        .foregroundColor(AppConfig.UI.secondaryTextColor)
                    
                    Spacer()
                    
                    // Price level
                    Text(String(repeating: "$", count: restaurant.priceLevel))
                        .font(.caption)
                        .foregroundColor(restaurant.priceLevel > 2 ? AppConfig.UI.accentColor : .green)
                }
                
                // Distance
                if let distance = restaurant.distance {
                    Text(formatDistance(distance))
                        .font(.caption)
                        .foregroundColor(AppConfig.UI.secondaryTextColor)
                }
                
                // Address (shortened)
                Text(restaurant.address)
                    .font(.caption)
                    .foregroundColor(AppConfig.UI.secondaryTextColor)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(width: 200)
            .background(AppConfig.UI.secondaryBackgroundColor)
            .cornerRadius(AppConfig.UI.cornerRadius)
        }
    }
    
    private func formatDistance(_ distance: Double) -> String {
        let distanceInKilometers = distance / 1000
        if distanceInKilometers < 1 {
            return String(format: "%.0f m away", distance)
        } else {
            return String(format: "%.1f km away", distanceInKilometers)
        }
    }
}

// Restaurant detail view
struct RestaurantDetailView: View {
    let restaurant: Restaurant
    @EnvironmentObject var dataStore: DataStore
    @EnvironmentObject var viewModel: AssistantViewModel
    @State private var showReservationSheet = false
    @State private var reservationDate = Date()
    @State private var partySize = 2
    @State private var showMapSheet = false
    @State private var showShareSheet = false
    @State private var reservationSuccess = false
    @State private var showReservationResult = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header with image
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 200)
                        .overlay(
                            Text("Restaurant Image")
                                .foregroundColor(.gray)
                        )
                    
                    VStack {
                        HStack {
                            Spacer()
                            
                            Button(action: {
                                viewModel.toggleFavorite(restaurant: restaurant)
                            }) {
                                Image(systemName: viewModel.isFavorite(restaurant: restaurant) ? "heart.fill" : "heart")
                                    .font(.title2)
                                    .padding(8)
                                    .background(Color.white.opacity(0.8))
                                    .clipShape(Circle())
                                    .foregroundColor(.red)
                            }
                            .padding()
                        }
                        
                        Spacer()
                    }
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    // Restaurant name and basics
                    HStack {
                        Text(restaurant.name)
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Spacer()
                        
                        // Price level
                        Text(String(repeating: "$", count: restaurant.priceLevel))
                            .font(.headline)
                            .foregroundColor(restaurant.priceLevel > 2 ? AppConfig.UI.accentColor : .green)
                    }
                    
                    // Cuisine
                    HStack {
                        ForEach(restaurant.cuisine, id: \.self) { cuisine in
                            Text(cuisine)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppConfig.UI.secondaryBackgroundColor)
                                .cornerRadius(10)
                        }
                    }
                    
                    // Rating
                    HStack {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= Int(restaurant.rating) ? "star.fill" :
                                (star == Int(restaurant.rating) + 1 && restaurant.rating.truncatingRemainder(dividingBy: 1) >= 0.5 ? "star.leadinghalf.fill" : "star"))
                                .foregroundColor(.yellow)
                        }
                        
                        Text(String(format: "%.1f", restaurant.rating))
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Description
                    if let description = restaurant.description {
                        Text("About")
                            .font(.headline)
                        
                        Text(description)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Address and contact
                    VStack(alignment: .leading, spacing: 8) {
                        Label(restaurant.address, systemImage: "mappin.and.ellipse")
                        
                        if let phoneNumber = restaurant.phoneNumber {
                            Button(action: {
                                if let url = URL(string: "tel:\(phoneNumber.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression))") {
                                    UIApplication.shared.open(url)
                                }
                            }) {
                                Label(phoneNumber, systemImage: "phone")
                                    .foregroundColor(.blue)
                            }
                        }
                        
                        if let website = restaurant.website, let url = URL(string: website) {
                            Button(action: {
                                UIApplication.shared.open(url)
                            }) {
                                Label("Visit Website", systemImage: "globe")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Hours
                    if let hours = restaurant.hours {
                        Text("Opening Hours")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(hours, id: \.self) { hour in
                                Text(hour)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding()
                
                // Action buttons
                HStack {
                    Spacer()
                    
                    // Map
                    Button(action: {
                        showMapSheet = true
                    }) {
                        VStack {
                            Image(systemName: "map")
                                .font(.title2)
                            Text("Map")
                                .font(.caption)
                        }
                        .frame(width: 60)
                    }
                    
                    Spacer()
                    
                    // Share
                    Button(action: {
                        showShareSheet = true
                    }) {
                        VStack {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                            Text("Share")
                                .font(.caption)
                        }
                        .frame(width: 60)
                    }
                    
                    Spacer()
                    
                    // Call
                    Button(action: {
                        if let phoneNumber = restaurant.phoneNumber,
                           let url = URL(string: "tel:\(phoneNumber.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression))") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        VStack {
                            Image(systemName: "phone")
                                .font(.title2)
                            Text("Call")
                                .font(.caption)
                        }
                        .frame(width: 60)
                    }
                    
                    Spacer()
                }
                .padding()
                .background(AppConfig.UI.secondaryBackgroundColor)
                .cornerRadius(AppConfig.UI.cornerRadius)
                .padding(.horizontal)
                
                // Reserve button
                if AppConfig.Features.enableReservations {
                    Button(action: {
                        showReservationSheet = true
                    }) {
                        Text("Make a Reservation")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(AppConfig.UI.primaryColor)
                            .cornerRadius(AppConfig.UI.cornerRadius)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
        }
        .navigationTitle("Restaurant Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    viewModel.toggleFavorite(restaurant: restaurant)
                }) {
                    Image(systemName: viewModel.isFavorite(restaurant: restaurant) ? "heart.fill" : "heart")
                        .foregroundColor(.red)
                }
            }
        }
        .sheet(isPresented: $showReservationSheet) {
            ReservationView(
                restaurant: restaurant,
                date: $reservationDate,
                partySize: $partySize,
                onReserve: {
                    // Simulate reservation process
                    reservationSuccess = viewModel.makeReservation(
                        restaurant: restaurant,
                        date: reservationDate,
                        partySize: partySize
                    )
                    showReservationSheet = false
                    showReservationResult = true
                },
                onCancel: {
                    showReservationSheet = false
                }
            )
        }
        .sheet(isPresented: $showMapSheet) {
            SingleRestaurantMapView(restaurant: restaurant)
                .edgesIgnoringSafeArea(.all)
        }
        .sheet(isPresented: $showShareSheet) {
            // Create shareable content about the restaurant
            let shareText = """
            Check out \(restaurant.name)!
            \(restaurant.cuisine.joined(separator: ", ")) cuisine
            Rating: \(restaurant.rating) stars
            \(restaurant.address)
            """
            
            ActivityView(activityItems: [shareText])
        }
        .alert(reservationSuccess ? "Reservation Confirmed" : "Reservation Failed", isPresented: $showReservationResult) {
            Button("OK") { showReservationResult = false }
        } message: {
            Text(reservationSuccess ?
                 "Your reservation at \(restaurant.name) for \(partySize) people on \(formattedDate(reservationDate)) has been confirmed." :
                 "Sorry, we couldn't complete your reservation. Please try again or call the restaurant directly.")
        }
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// Reservation view
struct ReservationView: View {
    let restaurant: Restaurant
    @Binding var date: Date
    @Binding var partySize: Int
    let onReserve: () -> Void
    let onCancel: () -> Void
    
    private let dateRange: ClosedRange<Date> = {
        let calendar = Calendar.current
        let startComponents = DateComponents(hour: 0, minute: 0, second: 0)
        let endComponents = DateComponents(day: 30, hour: 23, minute: 59, second: 59)
        return calendar.date(byAdding: startComponents, to: Date())!
             ...
             calendar.date(byAdding: endComponents, to: Date())!
    }()
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Date & Time")) {
                    DatePicker("Select Date and Time", selection: $date, in: dateRange)
                        .datePickerStyle(.compact)
                }
                
                Section(header: Text("Party Size")) {
                    Stepper(value: $partySize, in: 1...20) {
                        Label("\(partySize) \(partySize == 1 ? "person" : "people")", systemImage: "person.2")
                    }
                }
                
                Section {
                    Text("Restaurant policies may apply. Cancellation fees may be charged for no-shows.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    Button(action: onReserve) {
                        Text("Confirm Reservation")
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    .listRowBackground(AppConfig.UI.primaryColor)
                    .foregroundColor(.white)
                }
            }
            .navigationTitle("Reserve at \(restaurant.name)")
            .navigationBarItems(trailing: Button("Cancel", action: onCancel))
        }
    }
}

// Activity view for sharing
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// Map view for displaying restaurants
struct MapView: View {
    let restaurants: [Restaurant]
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var viewModel: AssistantViewModel
    @State private var selectedRestaurant: Restaurant?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                Map(coordinateRegion: $locationService.region, showsUserLocation: true, annotationItems: restaurants) { restaurant in
                    MapAnnotation(coordinate: restaurant.coordinates) {
                        Button(action: {
                            selectedRestaurant = restaurant
                        }) {
                            VStack {
                                Image(systemName: "fork.knife.circle.fill")
                                    .font(.title)
                                    .foregroundColor(AppConfig.UI.primaryColor)
                                
                                Text(restaurant.name)
                                    .font(.caption)
                                    .padding(4)
                                    .background(Color.white.opacity(0.8))
                                    .cornerRadius(4)
                                    .foregroundColor(.black)
                            }
                        }
                    }
                }
                .edgesIgnoringSafeArea(.all)
                
                VStack {
                    Spacer()
                    
                    if let restaurant = selectedRestaurant {
                        RestaurantPreviewCard(restaurant: restaurant)
                            .padding()
                            .transition(.move(edge: .bottom))
                    }
                }
            }
            .navigationTitle("Nearby Restaurants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        if let location = locationService.currentLocation {
                            locationService.region = MKCoordinateRegion(
                                center: location.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                            )
                        }
                    }) {
                        Image(systemName: "location")
                    }
                }
            }
        }
    }
}

// Map view for a single restaurant
struct SingleRestaurantMapView: View {
    let restaurant: Restaurant
    @Environment(\.dismiss) private var dismiss
    @State private var region: MKCoordinateRegion
    
    init(restaurant: Restaurant) {
        self.restaurant = restaurant
        self._region = State(initialValue: MKCoordinateRegion(
            center: restaurant.coordinates,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }
    
    var body: some View {
        NavigationView {
            Map(coordinateRegion: $region, showsUserLocation: true, annotationItems: [restaurant]) { restaurant in
                MapAnnotation(coordinate: restaurant.coordinates) {
                    VStack {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .foregroundColor(.red)
                        
                        Text(restaurant.name)
                            .font(.caption)
                            .padding(4)
                            .background(Color.white.opacity(0.8))
                            .cornerRadius(4)
                            .foregroundColor(.black)
                    }
                }
            }
            .edgesIgnoringSafeArea(.all)
            .navigationTitle(restaurant.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        // Get directions to restaurant
                        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: restaurant.coordinates))
                        mapItem.name = restaurant.name
                        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                    }) {
                        Image(systemName: "car")
                    }
                }
            }
        }
    }
}

// Restaurant mini card for map preview
struct RestaurantPreviewCard: View {
    let restaurant: Restaurant
    @EnvironmentObject var viewModel: AssistantViewModel
    
    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(restaurant.name)
                        .font(.headline)
                    
                    Text(restaurant.cuisine.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= Int(restaurant.rating) ? "star.fill" : "star")
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }
                        
                        if let distance = restaurant.distance {
                            Text("• \(formatDistance(distance))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                Button(action: {
                    viewModel.selectedRestaurant = restaurant
                }) {
                    Text("Details")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppConfig.UI.primaryColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    private func formatDistance(_ distance: Double) -> String {
        let distanceInKilometers = distance / 1000
        if distanceInKilometers < 1 {
            return String(format: "%.0f m", distance)
        } else {
            return String(format: "%.1f km", distanceInKilometers)
        }
    }
}

// Welcome view
struct WelcomeView: View {
    let isConnecting: Bool
    let connect: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(AppConfig.UI.primaryColor)
            
            Text("Food Finder")
                .font(.largeTitle)
                .bold()
            
            Text("Discover the perfect restaurant with your personal food assistant")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .foregroundColor(.secondary)
            
            Spacer()
            
            if isConnecting {
                ProgressView()
                    .padding()
                Text("Initializing...")
                    .foregroundColor(.secondary)
            } else {
                Button(action: connect) {
                    Text("Get Started")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(width: 200)
                        .background(AppConfig.UI.primaryColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            
            Spacer()
        }
        .padding()
    }
}

// Loading view
struct LoadingView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
                
                Text("Looking for restaurants...")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.top)
            }
            .padding(20)
            .background(Color.gray.opacity(0.7))
            .cornerRadius(12)
        }
    }
}

// Settings view
struct SettingsView: View {
    @EnvironmentObject var dataStore: DataStore
    @EnvironmentObject var viewModel: AssistantViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var dietaryPreferences: [String] = []
    @State private var maxPrice: Int = 4
    @State private var sortOption: UserPreferences.SortOption = .distance
    @State private var maxDistance: Double = 5.0
    
    let dietaryOptions = ["Vegetarian", "Vegan", "Gluten-Free", "Dairy-Free", "Nut-Free", "Halal", "Kosher", "Pescatarian"]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Search Preferences")) {
                    Picker("Sort By", selection: $sortOption) {
                        ForEach(UserPreferences.SortOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Maximum Price")
                        
                        HStack {
                            ForEach(1...4, id: \.self) { level in
                                Button(action: {
                                    maxPrice = level
                                }) {
                                    Text(String(repeating: "$", count: level))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(maxPrice >= level ? AppConfig.UI.primaryColor : Color.gray.opacity(0.2))
                                        .foregroundColor(maxPrice >= level ? .white : .primary)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Maximum Distance: \(String(format: "%.1f", maxDistance)) km")
                        
                        Slider(value: $maxDistance, in: 1...20, step: 1)
                            .accentColor(AppConfig.UI.primaryColor)
                    }
                }
                
                Section(header: Text("Dietary Preferences")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(dietaryOptions, id: \.self) { option in
                                Button(action: {
                                    if dietaryPreferences.contains(option) {
                                        dietaryPreferences.removeAll { $0 == option }
                                    } else {
                                        dietaryPreferences.append(option)
                                    }
                                }) {
                                    Text(option)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(dietaryPreferences.contains(option) ? AppConfig.UI.primaryColor : Color.gray.opacity(0.2))
                                        .foregroundColor(dietaryPreferences.contains(option) ? .white : .primary)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Section {
                    Button(action: {
                        // Save settings
                        dataStore.userPreferences.dietaryPreferences = dietaryPreferences
                        dataStore.userPreferences.pricePreference = maxPrice
                        dataStore.userPreferences.sortPreference = sortOption
                        dataStore.userPreferences.distancePreference = maxDistance * 1000
                        dataStore.saveData()
                        viewModel.sortOption = sortOption
                        dismiss()
                    }) {
                        Text("Save Settings")
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    .listRowBackground(AppConfig.UI.primaryColor)
                    .foregroundColor(.white)
                }
                
                Section {
                    Button(action: {
                        dataStore.clearChatHistory()
                        viewModel.messages = []
                    }) {
                        HStack {
                            Spacer()
                            Text("Clear Chat History")
                            Spacer()
                        }
                    }
                    .foregroundColor(.red)
                }
                
                Section(header: Text("About")) {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("AI Model")
                        Spacer()
                        Text(AppConfig.modelName)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .onAppear {
                // Load current settings
                dietaryPreferences = dataStore.userPreferences.dietaryPreferences
                maxPrice = dataStore.userPreferences.pricePreference ?? 4
                sortOption = dataStore.userPreferences.sortPreference
                maxDistance = (dataStore.userPreferences.distancePreference ?? 5000) / 1000
            }
        }
    }
}

// Favorites view
struct FavoritesView: View {
    @EnvironmentObject var dataStore: DataStore
    @EnvironmentObject var viewModel: AssistantViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    
    var filteredRestaurants: [Restaurant] {
        if searchText.isEmpty {
            return dataStore.favoriteRestaurants
        } else {
            return dataStore.favoriteRestaurants.filter { restaurant in
                restaurant.name.lowercased().contains(searchText.lowercased()) ||
                restaurant.cuisine.contains { cuisine in
                    cuisine.lowercased().contains(searchText.lowercased())
                }
            }
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                if dataStore.favoriteRestaurants.isEmpty {
                    ContentUnavailableView {
                        Label("No Favorites", systemImage: "heart.slash")
                    } description: {
                        Text("You haven't saved any favorite restaurants yet.")
                    } actions: {
                        Button(action: {
                            dismiss()
                        }) {
                            Text("Start Exploring")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppConfig.UI.primaryColor)
                    }
                } else if filteredRestaurants.isEmpty {
                    ContentUnavailableView {
                        Label("No Results", systemImage: "magnifyingglass")
                    } description: {
                        Text("No restaurants matched your search.")
                    }
                } else {
                    ForEach(filteredRestaurants) { restaurant in
                        Button(action: {
                            viewModel.selectedRestaurant = restaurant
                            dismiss()
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(restaurant.name)
                                        .font(.headline)
                                    
                                    Text(restaurant.cuisine.joined(separator: ", "))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    
                                    HStack {
                                        // Rating stars
                                        HStack(spacing: 2) {
                                            ForEach(1...5, id: \.self) { star in
                                                Image(systemName: star <= Int(restaurant.rating) ? "star.fill" : "star")
                                                    .font(.caption)
                                                    .foregroundColor(.yellow)
                                            }
                                        }
                                        
                                        Text(String(format: "%.1f", restaurant.rating))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        Text("• \(String(repeating: "$", count: restaurant.priceLevel))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                viewModel.toggleFavorite(restaurant: restaurant)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Favorites")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search favorites")
        }
    }
}

// MARK: - Extensions

extension Double {
    func rounded(to places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
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
