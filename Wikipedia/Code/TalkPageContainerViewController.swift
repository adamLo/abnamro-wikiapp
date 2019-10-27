
import UIKit

fileprivate enum TalkPageContainerViewState {
    case initial
    case fetchLoading
    case fetchInitialResultData
    case fetchInitialResultEmpty
    case fetchFinishedResultData
    case fetchFinishedResultEmpty
    case fetchFailure(error: Error)
    case linkLoading(loadingViewController: ViewController)
    case linkFinished(loadingViewController: ViewController)
    case linkFailure(loadingViewController: ViewController)
    
    var repliesAreDisabled: Bool {
        switch self {
        case .initial, .fetchLoading, .fetchInitialResultData, .fetchInitialResultEmpty, .fetchFailure, .linkLoading:
            return true
        case .fetchFinishedResultData, .fetchFinishedResultEmpty, .linkFinished, .linkFailure:
            return false
        }
    }
}

extension TalkPageContainerViewState: Equatable {
    
    public static func ==(lhs: TalkPageContainerViewState, rhs:TalkPageContainerViewState) -> Bool {
        switch (lhs, rhs) {
        case (.initial, .initial):
            return true
        case (.fetchLoading, .fetchLoading):
            return true
        case (.fetchInitialResultData, .fetchInitialResultData):
            return true
        case (.fetchInitialResultEmpty, .fetchInitialResultEmpty):
            return true
        case (.fetchFinishedResultData, .fetchFinishedResultData):
            return true
        case (.fetchFinishedResultEmpty, .fetchFinishedResultEmpty):
            return true
        case (.fetchFailure, .fetchFailure):
            return true
        case (.linkLoading, .linkLoading):
            return true
        case (.linkFinished, .linkFinished):
            return true
        case (.linkFailure, .linkFailure):
            return true
        default:
            return false
        }
    }
}

@objc(WMFTalkPageContainerViewController)
class TalkPageContainerViewController: ViewController, HintPresenting {
    
    let talkPageTitle: String
    private(set) var siteURL: URL
    let type: TalkPageType
    private let dataStore: MWKDataStore
    private(set) var controller: TalkPageController
    private(set) var talkPageSemanticContentAttribute: UISemanticContentAttribute
    private let emptyViewController = EmptyRefreshingViewController()
    private var talkPage: TalkPage? {
        didSet {
            guard let talkPage = self.talkPage else {
                introTopic = nil
                return
            }
            introTopic = talkPage.topics?.first(where: { ($0 as? TalkPageTopic)?.isIntro == true}) as? TalkPageTopic
            talkPage.userDidAccess()
            try? talkPage.managedObjectContext?.save()
        }
    }
    private var introTopic: TalkPageTopic?
    private var topicListViewController: TalkPageTopicListViewController?
    private var replyListViewController: TalkPageReplyListViewController?
    private var emptyContainerTopConstraint: NSLayoutConstraint?
    private var emptyView: WMFEmptyView?
    private var headerView: TalkPageHeaderView?
    private var addButton: UIBarButtonItem?
    
    private let toolbar = UIToolbar()
    private var shareIcon: IconBarButtonItem?
    private var languageIcon: IconBarButtonItem?
    private var completedActivityType: UIActivity.ActivityType?
    
    @objc static let WMFReplyPublishedNotificationName = "WMFReplyPublishedNotificationName"
    @objc static let WMFTopicPublishedNotificationName = "WMFTopicPublishedNotificationName"
    
    var hintController: HintController?
    var fromNavigationStateRestoration: Bool = false
    private var cancellationKey: String?
    
    private var currentLoadingViewController: ViewController?
    private var currentSourceView: UIView?
    private var currentSourceRect: CGRect?
    weak var loadingFlowController: LoadingFlowController?
    
    lazy private(set) var fakeProgressController: FakeProgressController = {
        let progressController = FakeProgressController(progress: navigationBar, delegate: navigationBar)
        progressController.delay = 0.0
        return progressController
    }()
    
    private var viewState: TalkPageContainerViewState = .initial {
        didSet {
            switch viewState {
            case .initial:
                self.scrollView?.isUserInteractionEnabled = true
                navigationItem.rightBarButtonItem?.isEnabled = false
            case .fetchLoading:
                fakeProgressController.start()
                navigationItem.rightBarButtonItem?.isEnabled = false
            case .fetchInitialResultData:
                navigationItem.rightBarButtonItem?.isEnabled = false
                hideEmptyView()
            case .fetchInitialResultEmpty:
                navigationItem.rightBarButtonItem?.isEnabled = false
                showEmptyView(of: .emptyTalkPage)
            case .fetchFinishedResultData:
                fakeProgressController.stop()
                navigationItem.rightBarButtonItem?.isEnabled = true
                hideEmptyView()
            case .fetchFinishedResultEmpty:
                fakeProgressController.stop()
                navigationItem.rightBarButtonItem?.isEnabled = true
                showEmptyView(of: .emptyTalkPage)
            case .fetchFailure (let error):
                fakeProgressController.stop()
                if oldValue != TalkPageContainerViewState.fetchInitialResultData {
                    showEmptyView(of: .unableToLoadTalkPage)
                }
                showNoInternetConnectionAlertOrOtherWarning(from: error)
            case .linkLoading(let viewController):
                viewController.scrollView?.isUserInteractionEnabled = false
                viewController.navigationItem.rightBarButtonItem?.isEnabled = false
            case .linkFinished(let viewController):
                viewController.scrollView?.isUserInteractionEnabled = true
                viewController.navigationItem.rightBarButtonItem?.isEnabled = true
            case .linkFailure(let viewController):
                viewController.scrollView?.isUserInteractionEnabled = true
                viewController.navigationItem.rightBarButtonItem?.isEnabled = true
            }
            
            replyListViewController?.repliesAreDisabled = viewState.repliesAreDisabled
        }
    }
    
    required init(title: String, siteURL: URL, type: TalkPageType, dataStore: MWKDataStore, controller: TalkPageController? = nil) {
        self.talkPageTitle = title
        self.siteURL = siteURL
        self.type = type
        self.dataStore = dataStore
        
        if let controller = controller {
            self.controller = controller
        } else {
            self.controller = TalkPageController(moc: dataStore.viewContext, title: talkPageTitle, siteURL: siteURL, type: type)
        }
        
        assert(title.contains(":"), "Title must already be prefixed with namespace.")
        
        let language = siteURL.wmf_language
        talkPageSemanticContentAttribute = MWLanguageInfo.semanticContentAttribute(forWMFLanguage: language)

        super.init()
    }
    
    @objc(containedUserTalkPageContainerWithURL:dataStore:theme:)
    static func containedUserTalkPageContainer(url: URL, dataStore: MWKDataStore, theme: Theme) -> LoadingFlowController? {
        guard
            let title = url.wmf_title,
            let siteURL = url.wmf_site
            else {
                return nil
        }
        return TalkPageContainerViewController.containedTalkPageContainer(title: title, siteURL: siteURL, dataStore: dataStore, type: .user, theme: theme)
    }

    private static func talkPageContainer(title: String, siteURL: URL, type: TalkPageType, dataStore: MWKDataStore) -> TalkPageContainerViewController {
        let strippedTitle = TalkPageType.user.titleWithoutNamespacePrefix(title: title)
        let titleWithPrefix = TalkPageType.user.titleWithCanonicalNamespacePrefix(title: strippedTitle, siteURL: siteURL)
        return TalkPageContainerViewController(title: titleWithPrefix, siteURL: siteURL, type: type, dataStore: dataStore)
    }
    
    static func containedTalkPageContainer(title: String, siteURL: URL, dataStore: MWKDataStore, type: TalkPageType, fromNavigationStateRestoration: Bool = false, theme: Theme) -> LoadingFlowController {
        let talkPageContainerVC = talkPageContainer(title: title, siteURL: siteURL, type: type, dataStore: dataStore)
        let loadingFlowController = LoadingFlowController(dataStore: dataStore, theme: theme, fetchDelegate: talkPageContainerVC, flowChild: talkPageContainerVC, url: siteURL)
        talkPageContainerVC.loadingFlowController = loadingFlowController
        talkPageContainerVC.fromNavigationStateRestoration = fromNavigationStateRestoration
        talkPageContainerVC.apply(theme: theme)
        return loadingFlowController
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        setupNavigationBar()
        setupToolbar()
        setupEmptyViewController()
        viewState = .initial
        fetch()
        
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    @objc private func didBecomeActive() {
        if completedActivityType == .openInSafari {
            fetch()
        }
        completedActivityType = nil
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if let emptyContainerTopConstraint = emptyContainerTopConstraint {
            emptyContainerTopConstraint.constant =  navigationBar.visibleHeight
        }
    }
    
    override func apply(theme: Theme) {
        super.apply(theme: theme)
        
        guard viewIfLoaded != nil else {
            return
        }
        
        view.backgroundColor = theme.colors.paperBackground
        toolbar.barTintColor = theme.colors.chromeBackground
        shareIcon?.apply(theme: theme)
        languageIcon?.apply(theme: theme)
        topicListViewController?.apply(theme: theme)
        replyListViewController?.apply(theme: theme)
        emptyViewController.apply(theme: theme)
        headerView?.apply(theme: theme)
    }

    func pushToReplyThread(topic: TalkPageTopic, animated: Bool = true) {
        let replyListViewController = TalkPageReplyListViewController(dataStore: dataStore, topic: topic, talkPageSemanticContentAttribute: talkPageSemanticContentAttribute)
        replyListViewController.delegate = self
        replyListViewController.apply(theme: theme)
        replyListViewController.repliesAreDisabled = viewState.repliesAreDisabled
        self.replyListViewController = replyListViewController
        navigationController?.pushViewController(replyListViewController, animated: animated)
    }
}

//MARK: Private

private extension TalkPageContainerViewController {
    
    func setupToolbar() {
        toolbar.barTintColor = theme.colors.chromeBackground
        
        let toolbarHeight = CGFloat(44)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(toolbar, belowSubview: navigationBar)
        let guide = view.safeAreaLayoutGuide
        let heightConstraint = toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight)
        let leadingConstraint = view.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor)
        let trailingConstraint = view.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor)
        let bottomConstraint = guide.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)
        
        NSLayoutConstraint.activate([heightConstraint, leadingConstraint, trailingConstraint, bottomConstraint])
        
        let shareIcon = IconBarButtonItem(iconName: "share", target: self, action: #selector(tappedShare(_:)), for: .touchUpInside)
        shareIcon.apply(theme: theme)
        shareIcon.accessibilityLabel = CommonStrings.accessibilityShareTitle
        
        let languageIcon = IconBarButtonItem(iconName: "language", target: self, action: #selector(tappedLanguage(_:)), for: .touchUpInside)
        languageIcon.apply(theme: theme)
        languageIcon.accessibilityLabel = CommonStrings.accessibilityLanguagesTitle
        
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbar.items = [spacer, languageIcon, spacer, shareIcon, spacer]
        
        self.shareIcon = shareIcon
        self.languageIcon = languageIcon
    }
    
    @objc func tappedLanguage(_ sender: UIButton) {
        
        let languagesVC = WMFPreferredLanguagesViewController.preferredLanguagesViewController()
        languagesVC?.delegate = self
        if let themeable = languagesVC as Themeable? {
            themeable.apply(theme: self.theme)
        }
        present(WMFThemeableNavigationController(rootViewController: languagesVC!, theme: self.theme), animated: true, completion: nil)
    }
    
    @objc func tappedShare(_ sender: UIButton) {
        var talkPageURLComponents = URLComponents(url: siteURL, resolvingAgainstBaseURL: false)
        talkPageURLComponents?.path = "/wiki/\(talkPageTitle)"
        guard let talkPageURL = talkPageURLComponents?.url else {
            return
        }
        let activityViewController = UIActivityViewController(activityItems: [talkPageURL], applicationActivities: [TUSafariActivity()])
        activityViewController.completionWithItemsHandler = { (activityType: UIActivity.ActivityType?, completed: Bool, _: [Any]?, _: Error?) in
            if completed {
                self.completedActivityType = activityType
            }
        }
        
        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
            popover.permittedArrowDirections = .down
        }
        
        present(activityViewController, animated: true)
    }
    
    func fetch(completion: (() -> Void)? = nil) {
        
        viewState = .fetchLoading
        
        controller.fetchTalkPage { [weak self] (result) in
            DispatchQueue.main.async {
                
                completion?()
                
                guard let self = self else {
                    return
                }
                
                switch result {
                case .success(let fetchResult):

                    
                    self.talkPage = try? self.dataStore.viewContext.existingObject(with: fetchResult.objectID) as? TalkPage
                    if let talkPage = self.talkPage {
                        
                        self.setupTopicListViewControllerIfNeeded(with: talkPage)
                        
                        if !talkPage.isEmpty {
                            self.viewState = fetchResult.isInitialLocalResult ? .fetchInitialResultData : .fetchFinishedResultData
                        } else {
                            self.viewState = fetchResult.isInitialLocalResult ? .fetchInitialResultEmpty : .fetchFinishedResultEmpty
                        }
                        
                        if let headerView = self.headerView {
                            self.configure(header: headerView, introTopic: self.introTopic)
                            self.updateScrollViewInsets()
                        }
                    } else {
                        self.viewState = fetchResult
                            .isInitialLocalResult ? .fetchInitialResultEmpty : .fetchFinishedResultEmpty
                    }
                case .failure(let error):
                    self.viewState = .fetchFailure(error: error)
                }
            }
        }
    }
    
    func setupEmptyViewController() {
        emptyViewController.delegate = self
        emptyViewController.apply(theme: theme)
        let constraints = addChildViewController(childViewController: emptyViewController, belowSubview: toolbar, topAnchorPadding: navigationBar.visibleHeight)
        emptyContainerTopConstraint = constraints.top
        emptyViewController.view.isHidden = true
    }
    
    func setupTopicListViewControllerIfNeeded(with talkPage: TalkPage) {
        if topicListViewController == nil {
            let topicListViewController = TalkPageTopicListViewController(dataStore: dataStore, talkPageTitle: talkPageTitle, talkPage: talkPage, siteURL: siteURL, type: type, talkPageSemanticContentAttribute: talkPageSemanticContentAttribute)
            topicListViewController.apply(theme: theme)
            topicListViewController.fromNavigationStateRestoration = fromNavigationStateRestoration
            fromNavigationStateRestoration = false
            let _ = addChildViewController(childViewController: topicListViewController, belowSubview: emptyViewController.view, topAnchorPadding: 0)
            topicListViewController.delegate = self
            self.topicListViewController = topicListViewController
        }
    }
    
    func resetTopicList() {
        topicListViewController?.willMove(toParent: nil)
        topicListViewController?.view.removeFromSuperview()
        topicListViewController?.removeFromParent()
        topicListViewController = nil
    }
    
    func addChildViewController(childViewController: UIViewController, belowSubview: UIView, topAnchorPadding: CGFloat) -> (top: NSLayoutConstraint, bottom: NSLayoutConstraint, leading: NSLayoutConstraint, trailing: NSLayoutConstraint) {
        addChild(childViewController)
        childViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(childViewController.view, belowSubview: belowSubview)
        
        let topConstraint = childViewController.view.topAnchor.constraint(equalTo: view.topAnchor, constant: topAnchorPadding)
        let bottomConstraint = childViewController.view.bottomAnchor.constraint(equalTo: toolbar.topAnchor)
        let leadingConstraint = childViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let trailingConstraint = childViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        NSLayoutConstraint.activate([topConstraint, bottomConstraint, leadingConstraint, trailingConstraint])
        childViewController.didMove(toParent: self)
        
        return (top: topConstraint, bottom: bottomConstraint, leading: leadingConstraint, trailing: trailingConstraint)
    }
    
    @objc func tappedAdd(_ sender: UIBarButtonItem) {
        let topicNewVC = TalkPageTopicNewViewController.init()
        topicNewVC.delegate = self
        topicNewVC.apply(theme: theme)
        navigationController?.pushViewController(topicNewVC, animated: true)
    }
    
    func setupAddBarButton() {
        let addButton = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(tappedAdd(_:)))
        addButton.tintColor = theme.colors.link
        addButton.accessibilityLabel = WMFLocalizedString("talk-page-add-discussion-accessibility-label", value: "Add discussion", comment: "Accessibility label for a button that opens the add new discussion screen.")
        navigationItem.rightBarButtonItem = addButton
        navigationBar.updateNavigationItems()
        self.addButton = addButton
        
    }
    
    func setupNavigationBar() {
        
        setupAddBarButton()
        
        if let headerView = TalkPageHeaderView.wmf_viewFromClassNib() {
            self.headerView = headerView
            configure(header: headerView, introTopic: nil)
            headerView.delegate = self
            navigationBar.isBarHidingEnabled = false
            navigationBar.isUnderBarViewHidingEnabled = true
            navigationBar.allowsUnderbarHitsFallThrough = true
            useNavigationBarVisibleHeightForScrollViewInsets = true
            navigationBar.addUnderNavigationBarView(headerView)
            navigationBar.underBarViewPercentHiddenForShowingTitle = 0.6
            navigationBar.title = controller.displayTitle
            updateScrollViewInsets()
        }
    }
    
    func configure(header: TalkPageHeaderView, introTopic: TalkPageTopic?) {
        
        var headerText: String
        switch type {
        case .user:
            headerText = WMFLocalizedString("talk-page-title-user-talk", value: "User Talk", comment: "This title label is displayed at the top of a talk page topic list, if the talk page type is a user talk page.").localizedUppercase
        case .article:
            headerText = WMFLocalizedString("talk-page-title-article-talk", value: "article Talk", comment: "This title label is displayed at the top of a talk page topic list, if the talk page type is an article talk page.").localizedUppercase
        }
        
        let languageTextFormat = WMFLocalizedString("talk-page-info-active-conversations", value: "Active conversations on %1$@ Wikipedia", comment: "This information label is displayed at the top of a talk page discussion list. %1$@ is replaced by the language wiki they are using - for example, 'Active conversations on English Wikipedia'.")
        
        let genericInfoText = WMFLocalizedString("talk-page-info-active-conversations-generic", value: "Active conversations on Wikipedia", comment: "This information label is displayed at the top of a talk page discussion list. This is fallback text in case a specific wiki language cannot be determined.")
        
        let infoText = stringWithLocalizedCurrentSiteLanguageReplacingPlaceholderInString(string: languageTextFormat, fallbackGenericString: genericInfoText)
        
        var introText: String?
        let sortDescriptor = NSSortDescriptor(key: "sort", ascending: true)
        if let first5IntroReplies = introTopic?.replies?.sortedArray(using: [sortDescriptor]).prefix(5) {
            let replyTexts = Array(first5IntroReplies).compactMap { return ($0 as? TalkPageReply)?.text }
            introText = replyTexts.joined(separator: "<br />")
        }
        
        let viewModel = TalkPageHeaderView.ViewModel(header: headerText, title: controller.displayTitle, info: infoText, intro: introText)
        
        header.configure(viewModel: viewModel)
        header.delegate = self
        header.semanticContentAttributeOverride = talkPageSemanticContentAttribute
        header.apply(theme: theme)
    }
    
    func stringWithLocalizedCurrentSiteLanguageReplacingPlaceholderInString(string: String, fallbackGenericString: String) -> String {
        
        if let code = siteURL.wmf_language,
            let language = (Locale.current as NSLocale).wmf_localizedLanguageNameForCode(code) {
            return NSString.localizedStringWithFormat(string as NSString, language) as String
        } else {
            return fallbackGenericString
        }
    }
    
    func absoluteURL(for url: URL) -> URL? {
        
        var absoluteUrl: URL?
        
        if let firstPathComponent = url.pathComponents.first,
            firstPathComponent == ".",
            url.host == nil,
            url.scheme == nil {
            
            var pathComponents = Array(url.pathComponents.dropFirst()) // replace ./ with wiki/
            pathComponents.insert("/wiki/", at: 0)
            
            absoluteUrl = siteURL.wmf_URL(withPath: pathComponents.joined(), isMobile: false)
            
        } else if url.host != nil && url.scheme != nil {
            absoluteUrl = url
        }
        
        return absoluteUrl
    }
    
    func pushTalkPage(title: String, siteURL: URL) {
        
        let loadingFlowController = TalkPageContainerViewController.containedTalkPageContainer(title: title, siteURL: siteURL, dataStore: dataStore, type: .user, theme: theme)
        self.navigationController?.pushViewController(loadingFlowController, animated: true)
    }
    
    func showUserActionSheet(siteURL: URL, absoluteURL: URL, sourceView: UIView, sourceRect: CGRect?) {
        
        let alertController = UIAlertController(title: WMFLocalizedString("talk-page-link-user-action-sheet-title", value: "User pages", comment: "Title of action sheet that displays when user taps a user page link in talk pages"), message: nil, preferredStyle: .actionSheet)
        let safariAction = UIAlertAction(title: WMFLocalizedString("talk-page-link-user-action-sheet-safari", value: "View User page in Safari", comment: "Title of action sheet button that takes user to a user page in Safari after tapping a user page link in talk pages."), style: .default) { (_) in
            self.openURLInSafari(url: absoluteURL)
        }
        let talkAction = UIAlertAction(title: WMFLocalizedString("talk-page-link-user-action-sheet-app", value: "View User Talk page in app", comment: "Title of action sheet button that takes user to a user talk page in the app after tapping a user page link in talk pages."), style: .default) { (_) in
            
            let title = absoluteURL.lastPathComponent
            if let firstColon = title.range(of: ":") {
                var titleWithoutNamespace = title
                titleWithoutNamespace.removeSubrange(title.startIndex..<firstColon.upperBound)
                let titleWithTalkPageNamespace = TalkPageType.user.titleWithCanonicalNamespacePrefix(title: titleWithoutNamespace, siteURL: siteURL)
                self.pushTalkPage(title: titleWithTalkPageNamespace, siteURL: siteURL)
            }
        }
        let cancelAction = UIAlertAction(title: CommonStrings.cancelActionTitle, style: .cancel, handler: nil)
        
        alertController.addAction(safariAction)
        alertController.addAction(talkAction)
        alertController.addAction(cancelAction)
        
        let rect = sourceRect ?? sourceView.bounds
        if let popover = alertController.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = rect
            popover.permittedArrowDirections = .any
        }
        
        present(alertController, animated: true, completion: nil)
    }
    
    func openURLInSafari(url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
    
    func toggleLinkDeterminationState(loadingViewController: FakeProgressLoading & ViewController, shouldDisable: Bool) {
        
        if shouldDisable {
            loadingViewController.fakeProgressController.start()
        } else {
            loadingViewController.fakeProgressController.stop()
        }
        
        loadingViewController.scrollView?.isUserInteractionEnabled = !shouldDisable
        loadingViewController.navigationItem.rightBarButtonItem?.isEnabled = !shouldDisable
    }
    
    func tappedLink(_ url: URL, loadingViewController: ViewController, sourceView: UIView, sourceRect: CGRect?) {
        
        self.currentLoadingViewController = loadingViewController
        self.currentSourceView = sourceView
        self.currentSourceRect = sourceRect
        
        self.viewState = .linkLoading(loadingViewController: loadingViewController)
        
        loadingFlowController?.tappedLink(url: url)
  
    }
    
    func changeLanguage(siteURL: URL) {
        controller = TalkPageController(moc: dataStore.viewContext, title: talkPageTitle, siteURL: siteURL, type: type)
        let language = siteURL.wmf_language
        talkPageSemanticContentAttribute = MWLanguageInfo.semanticContentAttribute(forWMFLanguage: language)
        resetTopicList()
        fetch { [weak self] in
            guard let self = self else {
                return
            }
            
            UIAccessibility.post(notification: UIAccessibility.Notification.screenChanged, argument: self.headerView?.infoLabel);
        }
    }
}

// MARK: Empty & error states

extension TalkPageContainerViewController {
    private func hideEmptyView() {
        emptyViewController.type = nil
        emptyViewController.view.isHidden = true
        navigationBar.setNavigationBarPercentHidden(0, underBarViewPercentHidden: 0, extendedViewPercentHidden: 0, topSpacingPercentHidden: 0, animated: true)
    }
    
    private func showEmptyView(of type: WMFEmptyViewType) {

        emptyViewController.type = type
        emptyViewController.view.isHidden = false
        
        navigationBar.setNavigationBarPercentHidden(0, underBarViewPercentHidden: 0, extendedViewPercentHidden: 0, topSpacingPercentHidden: 0, animated: true)
    }

    private func showNoInternetConnectionAlertOrOtherWarning(from error: Error, noInternetConnectionAlertMessage: String = CommonStrings.noInternetConnection) {

        if (error as NSError).wmf_isNetworkConnectionError() {
            
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: noInternetConnectionAlertMessage)
            } else {
                WMFAlertManager.sharedInstance.showErrorAlertWithMessage(noInternetConnectionAlertMessage, sticky: true, dismissPreviousAlerts: true)
            }
            
        } else if let talkPageError = error as? TalkPageError {
            
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: talkPageError.localizedDescription)
             } else {
                WMFAlertManager.sharedInstance.showWarningAlert(talkPageError.localizedDescription, sticky: true, dismissPreviousAlerts: true)
            }
            
        }  else {
            
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: error.localizedDescription)
            } else {
                WMFAlertManager.sharedInstance.showErrorAlertWithMessage(error.localizedDescription, sticky: true, dismissPreviousAlerts: true)
            }
            
        }
    }
    
    private func syncViewState() {
        //catches cases where view state may get out of sync with the topic data
        if let talkPage = talkPage {
            switch (viewState, talkPage.topics?.count ?? 0) {
            case (.fetchFinishedResultData, 0):
                viewState = .fetchFinishedResultEmpty
            case (.fetchFinishedResultEmpty, 1..<Int.max):
                viewState = .fetchFinishedResultData
            default:
                break
            }
        }
    }
}

//MARK: TalkPageTopicNewViewControllerDelegate

extension TalkPageContainerViewController: TalkPageTopicNewViewControllerDelegate {
    func tappedPublish(subject: String, body: String, viewController: TalkPageTopicNewViewController) {
        
        guard let talkPage = talkPage else {
            assertionFailure("Missing Talk Page")
            return
        }
        
        viewController.postDidBegin()
        controller.addTopic(toTalkPageWith: talkPage.objectID, title: talkPageTitle, siteURL: siteURL, subject: subject, body: body) { [weak self] (result) in
            
            guard let self = self else {
                return
            }
            
            DispatchQueue.main.async {
                viewController.postDidEnd()

                switch result {
                case .success(let result):
                    if result != .success {
                        self.fetch()
                    } else {
                        self.syncViewState()
                    }
                    
                    if !UIAccessibility.isVoiceOverRunning {
                        self.navigationController?.popViewController(animated: true)
                        NotificationCenter.default.post(name: Notification.Name(TalkPageContainerViewController.WMFTopicPublishedNotificationName), object: nil)
                    } else {
                        viewController.announcePostSuccessful()
                    }
                    
                case .failure(let error):
                    self.showNoInternetConnectionAlertOrOtherWarning(from: error, noInternetConnectionAlertMessage: WMFLocalizedString("talk-page-error-unable-to-post-topic", value: "No internet connection. Unable to post discussion.", comment: "Error message appearing when user attempts to post a new talk page discussion while being offline"))
                }
            }
        }
    }
}

//MARK: TalkPageTopicListDelegate

extension TalkPageContainerViewController: TalkPageTopicListDelegate {    
    func scrollViewDidScroll(_ scrollView: UIScrollView, viewController: TalkPageTopicListViewController) {
        hintController?.dismissHintDueToUserInteraction()
    }
    
    func tappedTopic(_ topic: TalkPageTopic, viewController: TalkPageTopicListViewController) {
        pushToReplyThread(topic: topic)
    }
    
    func didTriggerRefresh(viewController: TalkPageTopicListViewController) {
        fetch { viewController.endRefreshing() }
    }
}

//MARK: TalkPageReplyListViewControllerDelegate

extension TalkPageContainerViewController: TalkPageReplyListViewControllerDelegate {
    func tappedPublish(topic: TalkPageTopic, composeText: String, viewController: TalkPageReplyListViewController) {
        
        viewController.postDidBegin()
        controller.addReply(to: topic, title: talkPageTitle, siteURL: siteURL, body: composeText) { (result) in
            DispatchQueue.main.async {
                
                if !UIAccessibility.isVoiceOverRunning {
                    viewController.postDidEnd()
                }
                
                switch result {
                case .success:
                    if !UIAccessibility.isVoiceOverRunning {
                        NotificationCenter.default.post(name: Notification.Name(TalkPageContainerViewController.WMFReplyPublishedNotificationName), object: nil)
                    } else {
                        viewController.announcePostSuccessful()
                    }
                    
                case .failure(let error):
                    
                    if UIAccessibility.isVoiceOverRunning {
                        viewController.postDidEnd()
                    }
                    
                    self.showNoInternetConnectionAlertOrOtherWarning(from: error, noInternetConnectionAlertMessage: WMFLocalizedString("talk-page-error-unable-to-post-reply", value: "No internet connection. Unable to post reply.", comment: "Error message appearing when user attempts to post a new talk page reply while being offline"))
                }
            }
        }
    }
    
    func tappedLink(_ url: URL, viewController: TalkPageReplyListViewController, sourceView: UIView, sourceRect: CGRect?) {
        tappedLink(url, loadingViewController: viewController, sourceView: sourceView, sourceRect: sourceRect)
    }
    
    func didTriggerRefresh(viewController: TalkPageReplyListViewController) {
        fetch { viewController.endRefreshing() } 
    }
}

//MARK: TalkPageHeaderViewDelegate

extension TalkPageContainerViewController: TalkPageHeaderViewDelegate {
    func tappedLink(_ url: URL, headerView: TalkPageHeaderView, sourceView: UIView, sourceRect: CGRect?) {
        tappedLink(url, loadingViewController: self, sourceView: sourceView, sourceRect: sourceRect)
    }
    
    func tappedIntro(headerView: TalkPageHeaderView) {
        if let introTopic = self.introTopic {
            pushToReplyThread(topic: introTopic)
        }
    }
}

//MARK: EmptyRefreshingViewControllerDelegate

extension TalkPageContainerViewController: EmptyRefreshingViewControllerDelegate {
    func triggeredRefresh(refreshCompletion: @escaping () -> Void) {
        fetch {
            refreshCompletion()
        }
    }
}

//MARK: WMFPreferredLanguagesViewControllerDelegate

extension TalkPageContainerViewController: WMFPreferredLanguagesViewControllerDelegate {
    func languagesController(_ controller: WMFLanguagesViewController!, didSelectLanguage language: MWKLanguageLink!) {
        let newSiteURL = language.siteURL()
        if siteURL != newSiteURL {
                siteURL = newSiteURL
                changeLanguage(siteURL: siteURL)
        }
        controller.dismiss(animated: true, completion: nil)
    }
}

//MARK: WMFLoadingFlowControllerFetchDelegate

extension TalkPageContainerViewController: WMFLoadingFlowControllerFetchDelegate {
    func loadEmbedFetch(with url: URL, successHandler: @escaping (LoadingFlowControllerArticle, URL) -> Void, errorHandler: @escaping (Error) -> Void) -> URLSessionTask? {
        assertionFailure("not setup for load embed")
        return nil
    }
    
    func linkPushFetch(with url: URL, successHandler: @escaping (LoadingFlowControllerArticle, URL) -> Void, errorHandler: @escaping (Error) -> Void) -> URLSessionTask? {
        assertionFailure("not setup for session task link push fetch")
        return nil
    }
}

//MARK: LoadingFlowControllerTaskTrackingDelegate

extension TalkPageContainerViewController: LoadingFlowControllerTaskTrackingDelegate {

    func linkPushFetch(url: URL, successHandler: @escaping (LoadingFlowControllerArticle, URL) -> Void, errorHandler: @escaping (NSError, URL) -> Void) -> (cancellationKey: String, fetcher: Fetcher)? {
        guard let absoluteURL = absoluteURL(for: url), let key = absoluteURL.wmf_databaseKey else {
            errorHandler(TalkPageError.unableToDetermineAbsoluteURL as NSError, url)
            return nil
        }
        
        let cancellationKey = self.dataStore.articleSummaryController.updateOrCreateArticleSummaryForArticle(withKey: key) { [weak self] (article, error) in
            if let article = article {
                DispatchQueue.main.async {
                    successHandler(article, absoluteURL)
                }
                return
            }
            
            
            DispatchQueue.main.async {
            
                let calculatedError = error ?? NSError(domain: Fetcher.unexpectedResponseError.domain, code:Fetcher.unexpectedResponseError.code, userInfo: nil)
                errorHandler(calculatedError as NSError, absoluteURL)
                
                //reset loading state
                if let loadingViewController = self?.currentLoadingViewController {
                    self?.viewState = .linkFailure(loadingViewController: loadingViewController)
                    self?.currentLoadingViewController = nil
                }
            }
        }
        
        if let cancellationKey = cancellationKey {
            return (cancellationKey: cancellationKey, fetcher: self.dataStore.articleSummaryController.fetcher)
        }
        
        return nil
        
    }
    
}

//MARK: WMFLoadingFlowControllerChildProtocol

extension TalkPageContainerViewController: WMFLoadingFlowControllerChildProtocol {
    
    var customNavAnimationHandler: (UIViewController & Themeable)? {
        return currentLoadingViewController
    }
    
    func showDefaultLinkFailureWithError(_ error: Error) {
        showNoInternetConnectionAlertOrOtherWarning(from: error)
    }
    
    func handleCustomSuccess(with article: LoadingFlowControllerArticle, url: URL) -> Bool {
        
        defer {
            self.currentLoadingViewController = nil
            self.currentSourceView = nil
            self.currentSourceRect = nil
        }
        
        guard let loadingViewController = self.currentLoadingViewController,
        let sourceView = self.currentSourceView,
            let sourceRect = self.currentSourceRect else {
                return false
        }

        self.viewState = .linkFinished(loadingViewController: loadingViewController)
        
        switch article.namespace {
        case PageNamespace.user.rawValue:
            self.showUserActionSheet(siteURL: siteURL, absoluteURL: url, sourceView: sourceView, sourceRect: sourceRect)
            return true
        default:
            return false;
        }
    }
}

//MARK: FakeProgressLoading

extension TalkPageContainerViewController: FakeProgressLoading {
}
