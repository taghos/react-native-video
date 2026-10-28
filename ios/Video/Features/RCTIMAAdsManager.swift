#if USE_GOOGLE_IMA
    import Foundation
    import GoogleInteractiveMediaAds

    class RCTIMAAdsManager: NSObject, IMAAdsLoaderDelegate, IMAAdsManagerDelegate, IMALinkOpenerDelegate, IMAStreamManagerDelegate {
        private weak var _video: RCTVideo?
        private var _isPictureInPictureActive: () -> Bool

        /** Entry point for the SDK. Used to make ad requests. */
        private var adsLoader: IMAAdsLoader!
        /** Main point of interaction with the SDK. Created by the SDK as the result of an ad request. */
        private var adsManager: IMAAdsManager!
        /** References the stream manager from the IMA DAI SDK after successfully loading the DAI stream. */
        private var streamManager: IMAStreamManager?
        /** Ad container view for DAI - stored to ensure proper z-ordering */
        private var daiAdContainerView: UIView?
        /** spalla patch: CSAI ad container kept to gate touches to ad breaks */
        private var csaiAdContainerView: UIView?
        /** Picture-in-Picture proxy for DAI - stored to ensure proper Picture-in-Picture support */
        private var pipProxy: IMAPictureInPictureProxy?

        init(video: RCTVideo!, isPictureInPictureActive: @escaping () -> Bool) {
            _video = video
            _isPictureInPictureActive = isPictureInPictureActive

            super.init()
        }

        func setUpAdsLoader() {
            guard let _video else { return }
            let settings = IMASettings()
            if let adLanguage = _video.getAdLanguage() {
                settings.language = adLanguage
            }
            adsLoader = IMAAdsLoader(settings: settings)
            adsLoader.delegate = self
        }

        func setupDaiLoader() {
            guard let _video else { return }
            let settings = IMASettings()
            // Enable background playback only if PiP or playInBackground is enabled
            settings.enableBackgroundPlayback = _video.shouldEnableBackgroundPlayback()
            if let adLanguage = _video.getAdLanguage() {
                settings.language = adLanguage
            }
            adsLoader = IMAAdsLoader(settings: settings)
            adsLoader.delegate = self
        }

        func requestAds() {
            guard let _video else { return }
            // fixes RCTVideo --> RCTIMAAdsManager --> IMAAdsLoader --> IMAAdDisplayContainer --> RCTVideo memory leak.
            let adContainerView = UIView()
            adContainerView.backgroundColor = .clear
            // spalla patch: transparent overlay must not eat player-control
            // touches; interaction is enabled only while an ad break runs.
            adContainerView.isUserInteractionEnabled = false
            csaiAdContainerView = adContainerView
            _video.addSubview(adContainerView)

            // Enable Auto Layout to ensure the ad container resizes with the video view.
            adContainerView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                adContainerView.topAnchor.constraint(equalTo: _video.topAnchor),
                adContainerView.bottomAnchor.constraint(equalTo: _video.bottomAnchor),
                adContainerView.leadingAnchor.constraint(equalTo: _video.leadingAnchor),
                adContainerView.trailingAnchor.constraint(equalTo: _video.trailingAnchor),
            ])

            // Create ad display container for ad rendering.
            let adDisplayContainer = IMAAdDisplayContainer(adContainer: adContainerView, viewController: _video.reactViewController())

            let adTagUrl = _video.getAdTagUrl()
            let contentPlayhead = _video.getContentPlayhead()

            if adTagUrl != nil && contentPlayhead != nil {
                // Create an ad request with our ad tag, display container, and optional user context.
                let request = IMAAdsRequest(
                    adTagUrl: adTagUrl!,
                    adDisplayContainer: adDisplayContainer,
                    contentPlayhead: contentPlayhead,
                    userContext: nil
                )

                adsLoader.requestAds(with: request)
            }
        }

        func requestDaiStream() {
            guard let _video else { return }
            // fixes RCTVideo --> RCTIMAAdsManager --> IMAAdsLoader --> IMAAdDisplayContainer --> RCTVideo memory leak.
            let adContainerView = UIView(frame: _video.bounds)
            adContainerView.backgroundColor = .clear
            // spalla patch: see requestAds — touches only during ad breaks
            adContainerView.isUserInteractionEnabled = false
            _video.addSubview(adContainerView)
            // Store reference for later z-ordering management. DAI requires ad container to stay on top for proper ad UI visibility
            daiAdContainerView = adContainerView

            // Create ad display container for ad rendering.
            let adDisplayContainer = IMAAdDisplayContainer(adContainer: adContainerView, viewController: _video.reactViewController())

            let contentSourceID = _video.getContentSourceId()
            let videoID = _video.getVideoId()
            let imaVideoDisplay = _video.getIMAVideoDisplay()
            let assetKey = _video.getAssetKey()
            let adTagParameters = _video.getAdTagParameters()

            if let pip = _video.getPip() {
                pipProxy = IMAPictureInPictureProxy(avPictureInPictureControllerDelegate: pip)
            } else {
                pipProxy = nil
            }

            // Request DAI stream for VOD (Video On Demand)
            // Requires both contentSourceId (CMS ID) and videoId to identify the content
            if _video.isDAIVod() {
                let request = IMAVODStreamRequest(
                    contentSourceID: contentSourceID!,
                    videoID: videoID!,
                    adDisplayContainer: adDisplayContainer,
                    videoDisplay: imaVideoDisplay!,
                    pictureInPictureProxy: pipProxy,
                    userContext: nil
                )

                // Apply adTagParameters if provided
                if let adTagParams = adTagParameters {
                    request.adTagParameters = adTagParams
                }

                adsLoader.requestStream(with: request)
                // Request DAI stream for live content
                // Uses assetKey to identify the live stream
            } else if _video.isDAILive() {
                let request = IMALiveStreamRequest(
                    assetKey: assetKey!,
                    adDisplayContainer: adDisplayContainer,
                    videoDisplay: imaVideoDisplay!,
                    pictureInPictureProxy: pipProxy,
                    userContext: nil
                )

                // Apply adTagParameters if provided
                if let adTagParams = adTagParameters {
                    request.adTagParameters = adTagParams
                }

                adsLoader.requestStream(with: request)
            }
        }

        func releaseAds() {
            // CSAI
            if let adsManager {
                // Destroy AdsManager may be delayed for a few milliseconds
                // But what we want is it stopped producing sound immediately
                // Issue found on tvOS 17, or iOS if view detach & STARTED event happen at the same moment
                adsManager.volume = 0
                adsManager.pause()
                adsManager.destroy()
            }

            // DAI
            if let streamManager {
                streamManager.destroy()
                self.streamManager = nil

                daiAdContainerView?.removeFromSuperview()
                daiAdContainerView = nil
            }

            // spalla patch: drop the stale CSAI touch-blocking layer
            csaiAdContainerView?.removeFromSuperview()
            csaiAdContainerView = nil
        }

        // MARK: - Getters

        func getAdsLoader() -> IMAAdsLoader? {
            return adsLoader
        }

        func getAdsManager() -> IMAAdsManager? {
            return adsManager
        }

        // MARK: - IMAAdsLoaderDelegate

        func adsLoader(_: IMAAdsLoader, adsLoadedWith adsLoadedData: IMAAdsLoadedData) {
            guard let _video else { return }

            // Check if this is a stream manager (DAI) or ads manager (CSAI)
            // The adsLoadedData will contain either streamManager (for DAI) or adsManager (for CSAI)
            if let streamMgr = adsLoadedData.streamManager {
                streamManager = streamMgr
                streamManager?.delegate = self

                // Ensure ad container stays on top when stream initializes
                // This is critical for DAI as ad overlays need to be visible
                if let adContainerView = daiAdContainerView {
                    _video.bringSubviewToFront(adContainerView)
                }

                // For DAI, the stream manager + IMAVideoDisplay automatically load content
                // No need to extract a URL - the stream manager handles playback directly
                // Just initialize and the player will start automatically
                self.streamManager?.initialize(with: nil)
            } else {
                // CSAI: Client-side ad insertion - ads are inserted by the client app
                self.adsManager = adsLoadedData.adsManager
                self.adsManager?.delegate = self

                // Create ads rendering settings and tell the SDK to use the in-app browser.
                let adsRenderingSettings = IMAAdsRenderingSettings()
                adsRenderingSettings.linkOpenerDelegate = self
                adsRenderingSettings.linkOpenerPresentingController = _video.reactViewController()

                self.adsManager?.initialize(with: adsRenderingSettings)
            }
        }

        func adsLoader(_: IMAAdsLoader, failedWith adErrorData: IMAAdLoadingErrorData) {
            guard let _video else { return }

            if adErrorData.adError.message != nil {
                print("Error loading ads: " + adErrorData.adError.message!)
            }

            // CSAI
            if adsManager != nil {
                _video.setPaused(false)
            }

            // DAI
            // spalla patch: a stream-request LOAD failure never creates a
            // streamManager, so gate recovery on the source being DAI (not on
            // streamManager) — otherwise iOS hangs on a black screen with no
            // error while Android already falls back. Surface the error to JS
            // too, mirroring the Android DAI_REQUEST_ERROR path.
            if _video.isDaiSource() {
                _video.isSetSourceOngoing = false
                _video.applyNextSource()

                _video.onVideoError?([
                    "error": [
                        "code": "DAI_REQUEST_ERROR",
                        "localizedDescription": adErrorData.adError.message ?? "DAI stream request failed",
                        "domain": "RCTVideoIMA",
                    ],
                    "target": _video.reactTag as Any,
                ])

                // Handle DAI error by falling back to backup content if available
                // This provides resilience when DAI stream fails or is unavailable
                if let backupStreamUri = _video.getBackupStreamUri() {
                    print("DAI stream error occurred, falling back to backup stream URI: \(backupStreamUri)")
                    // Clean up DAI resources before switching to backup
                    releaseAds()
                    // Switch to backup stream - create a simple source dictionary with the URI
                    // The backup stream typically contains the content without ads
                    let backupSource: NSDictionary = [
                        "uri": backupStreamUri,
                        "isNetwork": true,
                    ]
                    DispatchQueue.main.async {
                        _video.setSrc(backupSource)
                    }
                }
            }
        }

        // MARK: - IMAAdsManagerDelegate

        func adsManager(_ adsManager: IMAAdsManager, didReceive event: IMAAdEvent) {
            guard let _video else { return }
            // Mute ad if the main player is muted
            if _video.isMuted() {
                adsManager.volume = 0
            }
            // Play each ad once it has been loaded
            if event.type == IMAAdEventType.LOADED {
                if _isPictureInPictureActive() {
                    return
                }
                adsManager.start()
            }

            if _video.onReceiveAdEvent != nil {
                let type = convertEventToString(event: event.type)

                if event.adData != nil {
                    _video.onReceiveAdEvent?([
                        "event": type,
                        "data": event.adData ?? [String](),
                        "target": _video.reactTag!,
                    ])
                } else {
                    _video.onReceiveAdEvent?([
                        "event": type,
                        "target": _video.reactTag!,
                    ])
                }
            }
        }

        func adsManager(_: IMAAdsManager, didReceive error: IMAAdError) {
            if error.message != nil {
                print("AdsManager error: " + error.message!)
            }

            guard let _video else { return }

            if _video.onReceiveAdEvent != nil {
                _video.onReceiveAdEvent?([
                    "event": "ERROR",
                    "data": [
                        "message": error.message ?? "",
                        "code": error.code,
                        "type": error.type,
                    ],
                    "target": _video.reactTag!,
                ])
            }

            // Fall back to playing content
            csaiAdContainerView?.isUserInteractionEnabled = false
            _video.setPaused(false)
        }

        func adsManagerDidRequestContentPause(_: IMAAdsManager) {
            // Pause the content for the SDK to play ads.
            csaiAdContainerView?.isUserInteractionEnabled = true
            _video?.setPaused(true)
            _video?.setAdPlaying(true)
            emitContentEvent("CONTENT_PAUSE_REQUESTED")
        }

        func adsManagerDidRequestContentResume(_: IMAAdsManager) {
            // Resume the content since the SDK is done playing ads (at least for now).
            csaiAdContainerView?.isUserInteractionEnabled = false
            _video?.setAdPlaying(false)
            _video?.setPaused(false)
            emitContentEvent("CONTENT_RESUME_REQUESTED")
        }

        // spalla patch: iOS IMA reports content pause/resume only through these
        // delegate callbacks, never as IMAAdEvents (Android emits both). With a
        // VMAP, ALL_ADS_COMPLETED only arrives after the last break, so JS never
        // learned that the pre-roll had ended.
        private func emitContentEvent(_ type: String) {
            guard let _video, _video.onReceiveAdEvent != nil else { return }
            _video.onReceiveAdEvent?([
                "event": type,
                "target": _video.reactTag!,
            ])
        }

        // MARK: - IMAStreamManagerDelegate

        func streamManager(_: IMAStreamManager, didReceive event: IMAAdEvent) {
            guard let _video else { return }

            // spalla patch: DAI overlay only grabs touches during ad breaks
            switch event.type {
            case .AD_BREAK_STARTED:
                daiAdContainerView?.isUserInteractionEnabled = true
            case .AD_BREAK_ENDED, .ALL_ADS_COMPLETED:
                daiAdContainerView?.isUserInteractionEnabled = false
            default:
                break
            }

            if _video.onReceiveAdEvent != nil {
                let type = convertEventToString(event: event.type)

                if event.adData != nil {
                    _video.onReceiveAdEvent?([
                        "event": type,
                        "data": event.adData ?? [String](),
                        "target": _video.reactTag!,
                    ])
                } else {
                    _video.onReceiveAdEvent?([
                        "event": type,
                        "target": _video.reactTag!,
                    ])
                }
            }
        }

        func streamManager(_: IMAStreamManager, didReceive error: IMAAdError) {
            if error.message != nil {
                print("AdsManager error: " + error.message!)
            }

            guard let _video else { return }

            if _video.onReceiveAdEvent != nil {
                _video.onReceiveAdEvent?([
                    "event": "ERROR",
                    "data": [
                        "message": error.message ?? "",
                        "code": error.code,
                        "type": error.type,
                    ],
                    "target": _video.reactTag!,
                ])
            }
        }

        // MARK: - IMALinkOpenerDelegate

        func linkOpenerDidClose(inAppLink _: NSObject) {
            adsManager?.resume()
        }

        // MARK: - Helpers

        func convertEventToString(event: IMAAdEventType!) -> String {
            var result = "UNKNOWN"

            switch event {
            case .AD_BREAK_READY:
                result = "AD_BREAK_READY"
            case .AD_BREAK_ENDED:
                result = "AD_BREAK_ENDED"
            case .AD_BREAK_STARTED:
                result = "AD_BREAK_STARTED"
            case .AD_PERIOD_ENDED:
                result = "AD_PERIOD_ENDED"
            case .AD_PERIOD_STARTED:
                result = "AD_PERIOD_STARTED"
            case .ALL_ADS_COMPLETED:
                result = "ALL_ADS_COMPLETED"
            case .CLICKED:
                result = "CLICK"
            case .COMPLETE:
                result = "COMPLETED"
            case .CUEPOINTS_CHANGED:
                result = "CUEPOINTS_CHANGED"
            case .FIRST_QUARTILE:
                result = "FIRST_QUARTILE"
            case .LOADED:
                result = "LOADED"
            case .LOG:
                result = "LOG"
            case .MIDPOINT:
                result = "MIDPOINT"
            case .PAUSE:
                result = "PAUSED"
            case .RESUME:
                result = "RESUMED"
            case .SKIPPED:
                result = "SKIPPED"
            case .STARTED:
                result = "STARTED"
            case .STREAM_LOADED:
                result = "STREAM_LOADED"
            case .TAPPED:
                result = "TAPPED"
            case .THIRD_QUARTILE:
                result = "THIRD_QUARTILE"
            default:
                result = "UNKNOWN"
            }

            return result
        }
    }
#endif
