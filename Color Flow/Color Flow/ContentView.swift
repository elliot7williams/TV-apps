//
//  ContentView.swift
//  Color Flow
//
//  Created by Elliot Williams on 2025-06-09.
//

import SwiftUI
import MediaPlayer
import Combine

// MARK: - Image Cache for Background Artwork
class ImageCache {
    static let shared = ImageCache()
    private var cache = NSCache<NSString, UIImage>()
    
    func set(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
    
    func get(forKey key: String) -> UIImage? {
        return cache.object(forKey: key as NSString)
    }
}

// MARK: - Year Formatting Extension
extension Int {
    var formattedYear: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }
}

// MARK: - MPMediaItem Extension for Year Property
extension MPMediaItem {
    var year: Int? {
        return value(forProperty: "year") as? Int
    }
}

// MARK: - Keyboard Dismiss Extension
extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - KeyWindow Extension
extension UIApplication {
    var keyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

struct MusicLibraryCoverFlow: View {
    // State Management
    @State private var albums: [Album] = []
    @State private var currentIndex = 0
    @State private var showPermissionAlert = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var flippedAlbumId: String?
    @State private var isDragging = false
    @State private var dragOffset: CGFloat = 0
    @State private var screenSize: CGSize = UIScreen.main.bounds.size
    @State private var searchCancellable: AnyCancellable?
    
    // Search State
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [Album] = []
    @State private var showSearchResults = false
    @State private var isSearchFieldFocused = false
    
    // Audio Playback
    @StateObject private var audioPlayer = AudioPlayerManager()
    @State private var nowPlayingItem: MPMediaItem?
    
    // Music Player
    private let musicPlayer = MPMusicPlayerController.applicationQueuePlayer
    
    // Visual Effects
    @State private var backgroundImage: UIImage?
    @State private var currentBackgroundAlbumId: String = ""
    @State private var reflectionOpacity: Double = 0.3
    
    // Momentum Scrolling
    @State private var momentumVelocity: CGFloat = 0
    @State private var isDecelerating = false
    @State private var lastDragPosition: CGFloat = 0
    @State private var lastDragTime: Date = Date()
    
    // Dynamic Cover Flow Configuration
    private var coverWidth: CGFloat {
        let baseWidth: CGFloat = 280
        let screenWidth = screenSize.width
        let screenHeight = screenSize.height
        
        // Scale up on larger screens
        if screenWidth > 800 || screenHeight > 800 {
            return baseWidth * 1.4
        } else if screenWidth > 500 {
            return baseWidth * 1.2
        }
        return baseWidth
    }
    
    private var coverHeight: CGFloat {
        return coverWidth // Maintain aspect ratio
    }
    
    private var spacing: CGFloat {
        return -coverWidth * 0.43 // Scale spacing with cover size
    }
    
    private var reflectionHeight: CGFloat {
        return coverHeight * 0.43 // Scale reflection with cover size
    }
    
    private let visibleAlbumsEachSide = 4
    private let preloadMargin = 10
    private let batchSize = 50
    
    var body: some View {
        ZStack {
            // Background with zoomed/blurred artwork
            backgroundView
            
            // Main Content
            Group {
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(error)
                } else if albums.isEmpty {
                    emptyLibraryView
                } else {
                    // MODIFIED: New layout structure
                    GeometryReader { geometry in
                        ZStack {
                            // Cover Flow
                            coverFlowView
                                .frame(height: coverHeight + reflectionHeight)
                                .position(x: geometry.size.width / 2,
                                          y: geometry.size.height / 2 + 42)
                            // Album Info and Controls
                            VStack(spacing: 5) {
                                // Current Album Info with buttons
                                currentAlbumInfoView
                                    .position(x: geometry.size.width / 2,
                                              y: (geometry.size.height / 2) - (coverHeight + reflectionHeight) / 2 + 438)
                                // Search Field (only in portrait)
                                if isPortrait {
                                    // Now Playing View
                                    nowPlayingView
                                        .position(x: geometry.size.width / 2, y: geometry.size.height - 145)
                                    controlsView
                                        .frame(height: geometry.size.height - 20)
                                        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 2)
                                }
                            }
                        }
                    }
                }
            }
        
            // Search results overlay
            if showSearchResults && !searchResults.isEmpty {
                searchResultsView.zIndex(5)
            }
        }
        .onChange(of: currentIndex) { _ in
            updateBackgroundArtwork()
        }
        .onChange(of: isDragging) { isDragging in
            if !isDragging && abs(momentumVelocity) > 1 {
                startDeceleration()
            }
        }
        .onChange(of: searchText) { newValue in
            // NEW: Cancel previous search task
            searchCancellable?.cancel()
            
            if newValue.isEmpty {
                searchResults = []
                showSearchResults = false
            } else {
                // NEW: Debounce search to avoid excessive updates
                searchCancellable = Just(newValue)
                    .delay(for: .seconds(0.2), scheduler: RunLoop.main) // 200ms delay
                    .sink { [self] value in
                        searchLibrary(for: value)
                        showSearchResults = true
                    }
            }
        }
        .onAppear {
            requestAuthorization()
            setupMusicPlayerObservers()
        }
        .onDisappear {
            removeMusicPlayerObservers()
        }
        .alert(isPresented: $showPermissionAlert) {
            Alert(
                title: Text("Music Library Access"),
                message: Text("Please enable access to your music library in Settings"),
                primaryButton: .default(Text("Settings"), action: openSettings),
                secondaryButton: .cancel()
            )
        }
    }
    
    // MARK: - Album Info View with Integrated Buttons
    private var currentAlbumInfoView: some View {
        ZStack() {
            HStack {
                if isPortrait {
                } else {
                    // Play/Pause Button (Left)
                    Button(action: togglePlayPause) {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.white).opacity(0.8)
                            .frame(width: 50, height: 50)
                            .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 2)
                    }
            }
                // Album Info (Center)
                VStack(spacing: 5) {
                    if currentIndex < albums.count {
                        let album = albums[currentIndex]
                        
                        // Album title
                        Text(album.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .frame(height: 15)
                            .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 2)
                        
                        // Artist name
                        Text(album.artist)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                        
                        // Year and track count
                        if let year = album.songs.first?.year {
                            Text("\(year.formattedYear) • \(album.songs.count) track\(album.songs.count == 1 ? "" : "s")")
                                .font(.system(size: 16, weight: .regular))
                                .foregroundColor(.white.opacity(0.7))
                                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        }
                    }
                }
                .frame(maxWidth: UIScreen.main.bounds.width - 145)
                .opacity(flippedAlbumId == albums[currentIndex].id ? 0 : 1)
                .animation(.easeInOut(duration: 0.3), value: flippedAlbumId)
                .opacity(isSearchFieldFocused ? 0 : 1) // Add this opacity modifier
                .animation(.easeInOut(duration: 0.3), value: isSearchFieldFocused)
                
                if isPortrait {
                } else {
                // Info Button (Right)
                Button(action: {
                    if currentIndex < albums.count {
                        let albumId = albums[currentIndex].id
                        withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.7)) {
                            flippedAlbumId = flippedAlbumId == albumId ? nil : albumId
                        }
                    }
                }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.white).opacity(0.8)
                        .frame(width: 50, height: 50)
                        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 2)
                }
                }
            }
        }
        .frame(maxHeight: UIScreen.main.bounds.width - 60)
        .zIndex(2)
    }
    
    // MARK: - Search Views
    
    private var searchResultsView: some View {
        HStack {
            Spacer()
            VStack {
                // Added header with title and close button
                HStack {
                    Text("Search Results")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.leading, 20)
                    
                    Spacer()
                    
                    Button(action: {
                        showSearchResults = false
                        isSearching = false
                        searchText = ""
                        withAnimation {
                            isSearchFieldFocused = false
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(.trailing, 20)
                    }
                }
                .padding(.top, 13)
                
                // NEW: Show loading indicator while searching
                if searchText.isEmpty == false && searchResults.isEmpty {
                    VStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("Searching...")
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Show "no results" message
                else if searchResults.isEmpty {
                    Text("No results found for \"\(searchText)\"")
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Show search results
                else {
                    List {
                        ForEach(searchResults) { album in
                            Button(action: {
                                // Find the index in albums
                                if let index = albums.firstIndex(where: { $0.id == album.id }) {
                                    currentIndex = index
                                    showSearchResults = false
                                    isSearching = false
                                    searchText = ""
                                    withAnimation {
                                        flippedAlbumId = nil
                                    }
                                }
                            }) {
                                HStack {
                                    if let representativeItem = album.songs.first {
                                        AlbumArtworkView(
                                            item: representativeItem,
                                            size: CGSize(width: 50, height: 50),
                                            isHighRes: false
                                        )
                                        .frame(width: 50, height: 50)
                                        .cornerRadius(4)
                                    } else {
                                        Color.gray
                                            .frame(width: 50, height: 50)
                                            .cornerRadius(4)
                                    }
                                    
                                    VStack(alignment: .leading) {
                                        Text(album.title)
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        
                                        Text(album.artist)
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.8))
                                    }
                                    .padding(.leading, 10)
                                    
                                    Spacer()
                                    
                                    Text("\(album.songs.count) songs")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
                }
            }
            .frame(maxWidth: min(UIScreen.main.bounds.width - 40, 500)) // Constrain width
            .background(
                VisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
                    .cornerRadius(12)
            )
            Spacer()
        }
        .padding(.top, 40) // Position below status bar
    }
    
    // MARK: - Music Player Setup
    private func setupMusicPlayerObservers() {
        musicPlayer.beginGeneratingPlaybackNotifications()
        
        // Playback state observer
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: musicPlayer,
            queue: .main
        ) { _ in
            audioPlayer.isPlaying = musicPlayer.playbackState == .playing
        }
        
        // Now playing item observer
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: musicPlayer,
            queue: .main
        ) { _ in
            nowPlayingItem = musicPlayer.nowPlayingItem
            updateCurrentTrackInfo()
        }
    }
    
    private func removeMusicPlayerObservers() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(
            self,
            name: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: musicPlayer
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: musicPlayer
        )
    }
    
    private func updateCurrentTrackInfo() {
        guard let nowPlaying = musicPlayer.nowPlayingItem else {
            audioPlayer.currentAlbumId = ""
            audioPlayer.currentTrackIndex = 0
            return
        }
        
        // Find the album and track index for the currently playing item
        for album in albums {
            if let index = album.songs.firstIndex(where: { $0.persistentID == nowPlaying.persistentID }) {
                audioPlayer.currentAlbumId = album.id
                audioPlayer.currentTrackIndex = index
                break
            }
        }
    }
    
    // MARK: - Views
    
    private var backgroundView: some View {
        Group {
            if let image = backgroundImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .edgesIgnoringSafeArea(.all)
                    .blur(radius: 50)
                    .overlay(Color.black.opacity(0.4))
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else {
                Color.black.edgesIgnoringSafeArea(.all)
            }
        }
    }
    
    // Add this new struct for the loading animation
    struct ColorfulLoadingView: View {
        @State private var dots: [Dot] = []
        @State private var textScale: CGFloat = 0.5
        @State private var phase: CGFloat = 0
        
        // Configuration
        let numberOfDots = 40  // Reduced for better performance
        let dotSizeRange: ClosedRange<CGFloat> = 20...80  // Larger circles
        let animationDuration: Double = 4.0
        let movementRange: ClosedRange<CGFloat> = -30...30
        
        struct Dot: Identifiable {
            let id = UUID()
            let size: CGFloat
            let color: Color
            let position: CGPoint
            let movement: CGSize  // Movement vector for floating effect
        }
        
        var body: some View {
                GeometryReader { geometry in
                    ZStack {
                        // Dark background
                        Color.black
                            .ignoresSafeArea()
                        
                        // Floating dots with parallax effect
                        ForEach(dots) { dot in
                            Circle()
                                .fill(dot.color)
                                .frame(width: dot.size, height: dot.size)
                                .position(
                                    x: dot.position.x + dot.movement.width * phase,
                                    y: dot.position.y + dot.movement.height * phase
                                )
                                .opacity(0.7)
                                .blur(radius: 3)
                                .animation(
                                    Animation.easeInOut(duration: animationDuration)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double.random(in: 0...animationDuration/2)),
                                    value: phase
                                )
                        }
                        
                        // Main content with depth effect
                        VStack {
                            Text("Loading your music library...")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.top, 40)
                                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                                .scaleEffect(textScale)
                                .offset(y: phase * -10)  // Subtle parallax
                            
                            Text("This may take a moment for large libraries")
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.7))
                                .padding(.top, 10)
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                .offset(y: phase * 5)  // Opposite parallax
                        }
                        .scaleEffect(1 + phase * 0.05)  // Breathing effect
                    }
                    .onAppear {
                        // Generate dots with movement vectors
                        dots = (0..<numberOfDots).map { _ in
                            Dot(
                                size: CGFloat.random(in: dotSizeRange),
                        color: Color(
                            hue: Double.random(in: 0...1),
                            saturation: 0.9,
                            brightness: 1.0
                            ),
                            position: CGPoint(
                                x: CGFloat.random(in: 0...geometry.size.width),
                                y: CGFloat.random(in: 0...geometry.size.height)
                                ),
                                movement: CGSize(
                                width: CGFloat.random(in: movementRange),
                                height: CGFloat.random(in: movementRange)
                            )
                        )
                    }
                    
                    // Animate text
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.5).delay(0.3)) {
                        textScale = 1.0
                    }
                                    
                    // Start floating animation
                    withAnimation(Animation.easeInOut(duration: animationDuration).repeatForever(autoreverses: true)) {
                    phase = 1
                    }
                }
            }
        }
    }
    
    private var loadingView: some View {
        ColorfulLoadingView()
    }
    
    private var emptyLibraryView: some View {
        VStack {
            Image(systemName: "music.note.list")
                .font(.system(size: 50))
                .foregroundColor(.white)
                .padding()
            
            Text("No albums found in your library")
                .font(.title2)
                .foregroundColor(.white)
                .padding()
            
            Button("Request Access") {
                requestAuthorization()
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.red)
            
            Text("Error Loading Library")
                .font(.title)
                .foregroundColor(.white)
            
            Text(message)
                .font(.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            Button("Retry") {
                requestAuthorization()
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
    }
    
    // MARK: - Cover Flow View
    private var coverFlowView: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let screenWidth = geometry.size.width
            
            ZStack {
                // Album covers
                ForEach(visibleAlbums) { album in
                    if let index = albums.firstIndex(where: { $0.id == album.id }) {
                        // Album and reflection container
                        VStack(spacing: 0) {
                            AlbumCoverView(
                                album: album,
                                isCurrent: index == currentIndex,
                                isFlipped: flippedAlbumId == album.id,
                                audioPlayer: audioPlayer,
                                playAlbumAction: {
                                    playAlbum(album)
                                },
                                playTrackAction: { trackIndex in
                                    playTrack(at: trackIndex, in: album)
                                },
                                flipAction: {
                                    if index == currentIndex {
                                        withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.7)) {
                                            flippedAlbumId = flippedAlbumId == album.id ? nil : album.id
                                        }
                                    }
                                },
                                isDragging: $isDragging
                            )
                            .frame(width: coverWidth, height: coverHeight)
                            
                            // Reflection - placed directly below the album
                            reflectionContent(for: album, index: index)
                                .frame(width: coverWidth, height: reflectionHeight)
                                .onTapGesture {
                                    hideKeyboard()
                                    showSearchResults = false
                                    isSearching = false
                                    withAnimation {
                                            isSearchFieldFocused = false
                                        }
                                }
                        }
                        .offset(x: positionOffset(for: index, in: screenWidth))
                        .zIndex(zIndex(for: index))
                        .scaleEffect(scaleEffect(for: index))
                        .opacity(opacityEffect(for: index))
                        .rotation3DEffect(
                            rotationAngle(for: index),
                            axis: (x: 0, y: 1, z: 0),
                            anchor: .center,
                            perspective: 0.5
                        )
                        .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
                    }
                }
            }
            .frame(width: geometry.size.width, height: coverHeight + reflectionHeight + 20)
            .position(x: centerX, y: (geometry.size.height / 2) + 10)
            .gesture(flippedAlbumId == nil ? dragGesture : nil)
            .overlay(
                // Add drag gesture overlay for flipping - only when not flipped
                Group {
                    if flippedAlbumId == nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 10)
                                    .onEnded { value in
                                        let swipeThreshold: CGFloat = 50
                                        if value.translation.width < -swipeThreshold {
                                            next()
                                        } else if value.translation.width > swipeThreshold {
                                            prev()
                                        }
                                    }
                            )
                    }
                }
            )
            .overlay(
                // Click zones like HTML version - only when not flipped
                Group {
                    if flippedAlbumId == nil {
                        HStack(spacing: 0) {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: geometry.size.width * 0.3)
                                .onTapGesture { prev() }
                            
                            Spacer()
                            
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: geometry.size.width * 0.3)
                                .onTapGesture { next() }
                        }
                    }
                }
            )
        }
        .frame(height: coverHeight + reflectionHeight)
    }
    
    private var controlsView: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .edgesIgnoringSafeArea(.all)
            
                VStack {
                    Spacer()
                    
                    // Search field at bottom center
                    HStack {
                        Spacer()
                        
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.black.opacity(0.7))
                                .padding(.leading, 8)
                            
                            TextField("Search", text: $searchText, onEditingChanged: { isEditing in
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isSearchFieldFocused = isEditing
                                }
                            })
                                .foregroundColor(.black)
                                .onSubmit {
                                    if !searchResults.isEmpty {
                                        showSearchResults = true
                                    }
                                }
                                .frame(maxWidth: 150)
                            
                            if !searchText.isEmpty {
                                Button(action: {
                                    searchText = ""
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.black.opacity(0.7))
                                        .padding(.trailing, 8)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.3).blur(radius: 5))
                        .cornerRadius(20)
                        
                        Spacer()
                    }
                    // Attach to very bottom
                    .padding(.bottom, UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? 0)
                }
            }
        }
    
    // NEW: Reflection opacity based on position
    private func reflectionOpacity(for index: Int) -> Double {
        let distance = abs(index - currentIndex)
        let opacity = 0.5 - (0.1 * Double(distance))
        return min(0.5, max(0.1, opacity))
    }

    // MARK: - Reflection Content
    private func reflectionContent(for album: Album, index: Int) -> some View {
        ZStack {
            if let representativeItem = album.songs.first {
                AlbumArtworkView(
                    item: representativeItem,
                    size: CGSize(width: coverWidth, height: coverHeight),
                    isHighRes: false
                )
                .scaleEffect(y: -1)
                .frame(width: coverWidth, height: reflectionHeight) // Use original cover width
                .clipped()
                .mask(
                    LinearGradient(
                        gradient: Gradient(colors: [.white.opacity(0.8), .clear]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blur(radius: 0.5)
                .saturation(0.7)
                .brightness(-0.1)
                .opacity(reflectionOpacity(for: index))
            }
        }
        .allowsHitTesting(false)
        .offset(y: -coverHeight * 0.11)
    }

    
    private var nowPlayingView: some View {
        VStack {
            if let nowPlaying = nowPlayingItem {
                VStack(spacing: 5) {
                    HStack(spacing: 30) {
                        Button(action: previousTrack) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white).opacity(0.5)
                                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 2)
                        }

                        Button(action: togglePlayPause) {
                            Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.white).opacity(0.5)
                                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 2)
                        }
                        
                        Button(action: nextTrack) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white).opacity(0.5)
                                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 2)
                        }
                    }
                    Text(nowPlaying.title ?? "Unknown Track")
                        .font(.title3)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 2)
                    
                    Text(nowPlaying.artist ?? "Unknown Artist")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 2)
                }
            }
        }
        .opacity(isSearchFieldFocused ? 0 : 1) // Add this opacity modifier
        .animation(.easeInOut(duration: 0.3), value: isSearchFieldFocused)
    }
    
    // MARK: - Search Functionality (updated for real-time search)
    private func searchLibrary(for query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        let lowercasedQuery = query.lowercased()
        
        // Run search in background to avoid UI lag
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Prioritize exact matches first
            let exactMatches = albums.filter {
                $0.title.lowercased() == lowercasedQuery ||
                $0.artist.lowercased() == lowercasedQuery
            }
            
            // Then partial matches
            let partialMatches = albums.filter {
                $0.title.lowercased().contains(lowercasedQuery) ||
                $0.artist.lowercased().contains(lowercasedQuery) ||
                $0.songs.contains { song in
                    (song.title?.lowercased().contains(lowercasedQuery) ?? false)
                }
            }
            
            // Combine results, removing duplicates
            var results = exactMatches
            for album in partialMatches {
                if !results.contains(where: { $0.id == album.id }) {
                    results.append(album)
                }
            }
            
            // Update UI on main thread
            DispatchQueue.main.async {
                self.searchResults = results
            }
        }
    }
    
    // MARK: - Gestures and Animations
    
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                let now = Date()
                let timeDelta = now.timeIntervalSince(lastDragTime)
                let positionDelta = value.translation.width - lastDragPosition
                
                // Calculate velocity (pixels per second)
                if timeDelta > 0 {
                    momentumVelocity = positionDelta / CGFloat(timeDelta)
                }
                
                // Dynamic acceleration based on speed
                let speedFactor = min(3.0, 1.0 + abs(momentumVelocity) / 500)
                dragOffset = value.translation.width * speedFactor
                lastDragPosition = value.translation.width
                lastDragTime = now
                
                // Only consider it dragging if movement exceeds threshold
                if abs(value.translation.width) > 10 || abs(value.translation.height) > 10 {
                    isDragging = true
                }
                
                // Auto-scroll when near edges with acceleration
                let screenWidth = UIScreen.main.bounds.width
                let distanceFromLeft = value.location.x
                let distanceFromRight = screenWidth - value.location.x
                let autoScrollThreshold: CGFloat = 80
                
                if distanceFromLeft < autoScrollThreshold && currentIndex > 0 {
                    let scrollAmount = pow((autoScrollThreshold - distanceFromLeft) / autoScrollThreshold, 2) * 15
                    dragOffset += scrollAmount
                    if currentIndex > 0 {
                        currentIndex -= 1
                        // Preload more albums when scrolling fast
                        if abs(momentumVelocity) > 800 {
                            currentIndex = max(0, currentIndex - 1)
                        }
                    }
                } else if distanceFromRight < autoScrollThreshold && currentIndex < albums.count - 1 {
                    let scrollAmount = pow((autoScrollThreshold - distanceFromRight) / autoScrollThreshold, 2) * 15
                    dragOffset -= scrollAmount
                    if currentIndex < albums.count - 1 {
                        currentIndex += 1
                        // Preload more albums when scrolling fast
                        if abs(momentumVelocity) > 800 {
                            currentIndex = min(albums.count - 1, currentIndex + 1)
                        }
                    }
                }
            }
            .onEnded { value in
                isDragging = false
                lastDragPosition = 0
                
                // Apply final position with momentum
                let threshold: CGFloat = 30
                if abs(momentumVelocity) > threshold {
                    startDeceleration()
                } else {
                    snapToNearestAlbum()
                }
            }
    }
    
    private func startDeceleration() {
        isDecelerating = true
        var currentVelocity = momentumVelocity
        let decelerationRate: CGFloat = 0.92
        
        // Animate the deceleration
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
            currentVelocity *= decelerationRate
            dragOffset += currentVelocity
            
            // Skip albums during fast deceleration
            if abs(currentVelocity) > 600 {
                let skipAmount = Int(abs(currentVelocity) / 600)
                if currentVelocity > 0 && currentIndex > 0 {
                    // Flip back if currently flipped
                    withAnimation {
                        self.flippedAlbumId = nil
                    }
                    currentIndex = max(0, currentIndex - skipAmount)
                } else if currentVelocity < 0 && currentIndex < albums.count - 1 {
                    // Flip back if currently flipped
                    withAnimation {
                        self.flippedAlbumId = nil
                    }
                    currentIndex = min(albums.count - 1, currentIndex + skipAmount)
                }
            }
            
            if abs(currentVelocity) < 1 {
                timer.invalidate()
                isDecelerating = false
                snapToNearestAlbum()
            }
        }
    }
    
    private func snapToNearestAlbum() {
        let dragThreshold: CGFloat = coverWidth / 2
        if dragOffset < -dragThreshold && currentIndex < albums.count - 1 {
            // Flip back if currently flipped
            withAnimation {
                flippedAlbumId = nil
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                currentIndex += 1
            }
        } else if dragOffset > dragThreshold && currentIndex > 0 {
            // Flip back if currently flipped
            withAnimation {
                flippedAlbumId = nil
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                currentIndex -= 1
            }
        }
        dragOffset = 0
        momentumVelocity = 0
    }
    
    // MARK: - Position and Animation Helpers
        
    private func positionOffset(for index: Int, in width: CGFloat) -> CGFloat {
        let offset = CGFloat(index - currentIndex)
        let baseOffset = offset * (coverWidth + spacing)
        
        if isDragging || isDecelerating {
            return baseOffset + dragOffset
        }
        
        let distance = abs(offset)
        
        if distance == 0 {
            return baseOffset
        }
        else if distance <= CGFloat(visibleAlbumsEachSide) {
            let direction: CGFloat = offset < 0 ? -1 : 1
            let fraction = distance / CGFloat(visibleAlbumsEachSide + 1)
            let perspectiveOffset = direction * (coverWidth * 0.7 * (1 - pow(fraction, 0.7)))
            return baseOffset + perspectiveOffset
        }
        else {
            let direction: CGFloat = offset < 0 ? -1 : 1
            return baseOffset + (direction * coverWidth * 0.25)
        }
    }

    private func rotationAngle(for index: Int) -> Angle {
        let offset = CGFloat(index - currentIndex)
        let distance = abs(offset)
        
        if distance == 0 {
            return .degrees(0)
        }
        else if distance <= CGFloat(visibleAlbumsEachSide) {
            let direction: CGFloat = offset < 0 ? -1 : 1
            let fraction = distance / CGFloat(visibleAlbumsEachSide + 1)
            return .degrees(direction * 75 * (1 - pow(fraction, 0.8))) // Reduced max rotation
        }
        else {
            return .degrees(0)
        }
    }
    
    private func scaleEffect(for index: Int) -> CGFloat {
        let offset = CGFloat(abs(index - currentIndex))
        
        if offset == 0 {
            return 1.0
        }
        else if offset <= CGFloat(visibleAlbumsEachSide) {
            return max(0.6, 1.0 - (0.1 * offset)) // More dramatic scaling
        }
        else {
            return 0.6
        }
    }
    
    private func opacityEffect(for index: Int) -> Double {
        let offset = CGFloat(abs(index - currentIndex))
        let opacity = 1.0 - (0.15 * (offset - CGFloat(visibleAlbumsEachSide)))
        return min(1.0, max(0, opacity))
    }
    
    private func zIndex(for index: Int) -> Double {
        if index == currentIndex {
            return 1000
        }
        else if abs(index - currentIndex) <= visibleAlbumsEachSide {
            return 500 - Double(abs(index - currentIndex))
        }
        else {
            return 100 - Double(abs(index - currentIndex))
        }
    }
    
    // MARK: - Background Artwork Management
    
    private func updateBackgroundArtwork() {
        guard currentIndex < albums.count else { return }
        let album = albums[currentIndex]
        
        // Don't reload if we already have this background
        guard album.id != currentBackgroundAlbumId else { return }
        
        // Use cached image if available
        if let cachedImage = ImageCache.shared.get(forKey: album.id) {
            self.backgroundImage = cachedImage
            self.currentBackgroundAlbumId = album.id
            return
        }
        
        // Delay the loading slightly during fast scrolling
        if isDragging || isDecelerating {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.loadBackgroundArtwork(for: album)
            }
        } else {
            loadBackgroundArtwork(for: album)
        }
    }
    
    private func loadBackgroundArtwork(for album: Album) {
        if let representativeItem = album.songs.first, let artwork = representativeItem.artwork {
            // Capture screen size on main thread
            let targetSize = CGSize(width: UIScreen.main.bounds.width * 2,
                                    height: UIScreen.main.bounds.height * 2)
            
            DispatchQueue.global(qos: .userInitiated).async {
                if artwork.bounds.isEmpty == false {
                    if let cachedImage = ImageCache.shared.get(forKey: album.id) {
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                self.backgroundImage = cachedImage
                                self.currentBackgroundAlbumId = album.id
                            }
                        }
                        return
                    }
                    
                    let image = artwork.image(at: targetSize)
                    if let image = image {
                        // Cache the image
                        ImageCache.shared.set(image, forKey: album.id)
                    }
                    
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.backgroundImage = image
                            self.currentBackgroundAlbumId = album.id
                        }
                    }
                }
            }
        } else {
            self.backgroundImage = nil
        }
    }
    
    // MARK: - Music Library Access
    
    private func requestAuthorization() {
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.loadAlbums()
                case .denied, .restricted:
                    self.errorMessage = "Music library access denied. Please enable access in Settings."
                    self.showPermissionAlert = true
                    self.isLoading = false
                case .notDetermined:
                    self.errorMessage = "Music library access not determined."
                    self.isLoading = false
                @unknown default:
                    self.errorMessage = "Unknown authorization status."
                    self.isLoading = false
                }
            }
        }
    }
    
    private func loadAlbums() {
        DispatchQueue.global(qos: .userInitiated).async {
            let query = MPMediaQuery.albums()
            let collections = query.collections ?? []
            var processedAlbums: [Album] = []
            
            for batchStart in stride(from: 0, to: collections.count, by: self.batchSize) {
                let batchEnd = min(batchStart + self.batchSize, collections.count)
                let batch = collections[batchStart..<batchEnd]
                
                let batchAlbums = batch.compactMap { collection -> Album? in
                    guard let representativeItem = collection.representativeItem else { return nil }
                    return Album(
                        id: String(representativeItem.albumPersistentID),
                        title: representativeItem.albumTitle ?? "Unknown Album",
                        artist: representativeItem.albumArtist ?? "Unknown Artist",
                        songs: collection.items
                    )
                }
                
                processedAlbums.append(contentsOf: batchAlbums)
                
                if batchEnd % (self.batchSize * 4) == 0 {
                    DispatchQueue.main.async {
                        self.albums = processedAlbums.sorted { $0.title < $1.title }
                    }
                }
            }
            
            let sortedAlbums = processedAlbums.sorted { $0.title < $1.title }
            DispatchQueue.main.async {
                self.albums = sortedAlbums
                self.isLoading = false
                if !sortedAlbums.isEmpty {
                    self.currentIndex = 0
                    self.updateBackgroundArtwork()
                }
            }
        }
    }
    
    // MARK: - Playback Controls
    
    private func playAlbum(_ album: Album) {
        guard !album.songs.isEmpty else { return }
        playTrack(at: 0, in: album)
    }
    
    private func togglePlayPause() {
        if musicPlayer.playbackState == .playing {
            musicPlayer.pause()
            audioPlayer.isPlaying = false
        } else {
            musicPlayer.play()
            audioPlayer.isPlaying = true
        }
    }
    
    private func previousTrack() {
        musicPlayer.skipToPreviousItem()
    }
    
    private func nextTrack() {
        musicPlayer.skipToNextItem()
    }
    
    private func playTrack(at index: Int, in album: Album) {
        guard index >= 0 && index < album.songs.count else { return }
        
        let song = album.songs[index]
        
        // Create a media item collection
        let collection = MPMediaItemCollection(items: album.songs)
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: collection)
        
        // Set queue and start playback
        musicPlayer.setQueue(with: descriptor)
        musicPlayer.nowPlayingItem = song
        musicPlayer.play()
        
        // Update player state
        audioPlayer.currentTrackIndex = index
        audioPlayer.currentAlbumId = album.id
        audioPlayer.isPlaying = true
        nowPlayingItem = song
    }
    
    private func next() {
        if currentIndex < albums.count - 1 {
            // Flip back if currently flipped
            withAnimation {
                flippedAlbumId = nil
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                currentIndex += 1
            }
        }
    }
    
    private func prev() {
        if currentIndex > 0 {
            // Flip back if currently flipped
            withAnimation {
                flippedAlbumId = nil
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                currentIndex -= 1
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private var visibleAlbums: [Album] {
        guard currentIndex < albums.count else { return [] }
        let start = max(0, currentIndex - preloadMargin)
        let end = min(albums.count - 1, currentIndex + preloadMargin)
        return Array(albums[start...end])
    }
    
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Album Cover View

struct AlbumCoverView: View {
    let album: Album
    let isCurrent: Bool
    let isFlipped: Bool
    @ObservedObject var audioPlayer: AudioPlayerManager
    let playAlbumAction: () -> Void
    let playTrackAction: (Int) -> Void
    let flipAction: () -> Void
    @Binding var isDragging: Bool
    
    var body: some View {
        ZStack {
            // Front view
            frontView
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(.degrees(isFlipped ? -90 : 0), axis: (x: 0, y: 1, z: 0))
            
            // Back view
            backView
                .opacity(isFlipped ? 1 : 0)
                .rotation3DEffect(.degrees(isFlipped ? 0 : 90), axis: (x: 0, y: 1, z: 0))
        }
        .rotation3DEffect(
            Angle(degrees: isFlipped ? 180 : 0),
            axis: (x: 0, y: 1, z: 0),
            anchor: .center,
            anchorZ: 0,
            perspective: 0.5
        )
        .onTapGesture {
            // Only flip if not currently dragging AND this is the current album
            if !isDragging && isCurrent {
                flipAction()
            }
        }
    }
    
    private var frontView: some View {
        ZStack {
            if let representativeItem = album.songs.first {
                // NEW: Added glossy overlay for glass effect
                ZStack {
                    AlbumArtworkView(
                        item: representativeItem,
                        size: CGSize(width: 500, height: 500),
                        isHighRes: true
                    )
                    
                    // Glossy overlay
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(0.15),
                                    Color.clear,
                                    Color.white.opacity(0.05)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .cornerRadius(8)
                .shadow(radius: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
            } else {
                placeholderView
            }
        }
        .frame(width: 300, height: 300)
        .contentShape(Rectangle())
    }
    
    private var backView: some View {
        ZStack {
        // Updated glass effect with proper layering
        ZStack {
            VisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
                .cornerRadius(8)
            
            // Subtle white overlay for glass effect
                Color.white.opacity(0.1)
                .cornerRadius(8)
            }
            .shadow(radius: 8)
            
            VStack(spacing: 8) {
                // Album title at the top
                Text(album.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                
                // Artist name
                Text(album.artist)
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                
                // Genre and year if available
                if let genre = album.songs.first?.genre,
                   let year = album.songs.first?.year {
                    Text("\(genre) • \(year.formattedYear)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                
                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.horizontal, 8)
                
                // Track list with track numbers
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(album.songs.indices, id: \.self) { index in
                            VStack(spacing: 0) {
                                Button(action: {
                                    playTrackAction(index)
                                }) {
                                    HStack(alignment: .center, spacing: 8) {
                                        // Track number - added here
                                        Text("\(index + 1).")
                                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.8))
                                            .frame(width: 27, alignment: .trailing)
                                        
                                        // Play/pause icon
                                        Image(systemName:
                                            audioPlayer.currentAlbumId == album.id &&
                                            audioPlayer.currentTrackIndex == index &&
                                            audioPlayer.isPlaying ?
                                            "pause.fill" : "play.fill"
                                        )
                                        .font(.system(size: 14))
                                        .frame(width: 24, height: 24)
                                        .foregroundColor(.white)
                                        
                                        // Track info
                                        VStack(alignment: .leading) {
                                            Text(album.songs[index].title ?? "Unknown Track")
                                                .font(.system(size: 14))
                                                .foregroundColor(.white)
                                                .lineLimit(1)
                                            
                                            let duration = album.songs[index].playbackDuration
                                            Text(timeString(from: duration))
                                                .font(.system(size: 10))
                                                .foregroundColor(.white.opacity(0.6))
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 8)
                                }
                                
                                // Separator line between tracks
                                if index < album.songs.count - 1 {
                                    Divider()
                                        .background(Color.white.opacity(0.2))
                                        .padding(.leading, 56) // Adjusted for track numbers
                                        .padding(.trailing, 8)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 300)
            }
            .padding(8)
            // This fixes the backwards text issue
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .frame(width: 300, height: 300)
    }
    
    private var placeholderView: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [.blue, .purple]),
                         startPoint: .topLeading,
                         endPoint: .bottomTrailing)
            Text(album.title)
                .foregroundColor(.white)
                .padding()
                .multilineTextAlignment(.center)
        }
        .cornerRadius(8)
    }
    
    // Helper function to format duration
    private func timeString(from timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Data Models

struct Album: Identifiable {
    let id: String
    let title: String
    let artist: String
    let songs: [MPMediaItem]
}

class AudioPlayerManager: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTrackIndex = 0
    var currentAlbumId: String = ""
}

// MARK: - Artwork View

struct AlbumArtworkView: View {
    let item: MPMediaItem
    let size: CGSize
    let isHighRes: Bool
    
    @State private var artworkImage: UIImage?
    
    var body: some View {
        Group {
            if let image = artworkImage {
                Image(uiImage: image)
                    .resizable()
            } else {
                Color.gray
                    .onAppear { loadArtwork() }
            }
        }
    }
    
    private func loadArtwork() {
        DispatchQueue.global(qos: .userInitiated).async {
            let targetSize = self.isHighRes ? self.size : CGSize(
                width: self.size.width / 2,
                height: self.size.height / 2
            )
            
            if let artwork = self.item.artwork {
                if artwork.bounds.isEmpty == false {
                    let image = artwork.image(at: targetSize)
                    DispatchQueue.main.async {
                        self.artworkImage = image
                    }
                }
            }
        }
    }
}

// MARK: - Visual Effect View (for blur effects)

struct VisualEffectView: UIViewRepresentable {
    var effect: UIVisualEffect?
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        return UIVisualEffectView()
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = effect
    }
}

// MARK: - Preview

struct MusicLibraryCoverFlow_Previews: PreviewProvider {
    static var previews: some View {
        MusicLibraryCoverFlow()
    }
}
