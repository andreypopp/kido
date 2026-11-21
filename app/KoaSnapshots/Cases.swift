enum KoaSelection {
    case all
    case captures(Set<String>)
}

enum KoaFixture: String, CaseIterable {
    case placeInset = "PlaceInset"
    case quoteSelection = "QuoteSelection"
    case dots = "Dots"
    case runStepsTransitions = "RunStepsTransitions"
    case scrollbarJumpMountsHistory = "ScrollbarJumpMountsHistory"
    case selectAllCopiesTheWholeTranscript = "SelectAllCopiesTheWholeTranscript"
    case findSkippedHistory = "FindSkippedHistory"
    case bangCompletion = "BangCompletion"
    case bang = "Bang"
    case composerFootResponsive = "ComposerFootResponsive"
    case composerFootStates = "ComposerFootStates"
    case composerStateGeometryWide = "ComposerStateGeometryWide"
    case composerStateGeometryNarrow = "ComposerStateGeometryNarrow"
    case focusBorderTranscript = "FocusBorderTranscript"
    case composerFocus = "ComposerFocus"
    case commandsNarrow = "CommandsNarrow"
    case mockupStates = "MockupStates"
    case notices = "Notices"
    case latest = "Latest"
    case errorState = "ErrorState"
    case shortStates = "ShortStates"
    case narrowStates = "NarrowStates"
    case dialogs = "Dialogs"
    case controls = "Controls"
    case narrowControls = "NarrowControls"
    case exit = "Exit"
    case failed = "Failed"
    case rhythm = "Rhythm"
    case threadsModes = "ThreadsModes"
    case threads = "Threads"
    case threadsFilter = "ThreadsFilter"
    case threadsFilterPanel = "ThreadsFilterPanel"
    case agents = "Agents"
    case subagentView = "SubagentView"
    case viewBar = "ViewBar"
    case jobs = "Jobs"
    case lightbox = "Lightbox"
    case paths = "Paths"
    case previewHover = "PreviewHover"
    case media = "Media"
    case attachments = "Attachments"
    case userMarkdown = "UserMarkdown"
    case reveal = "Reveal"
    case thinkingMarkdown = "ThinkingMarkdown"
    case composerMarkdown = "ComposerMarkdown"
    case questions = "Questions"
    case completion = "Completion"
    case sessions = "Sessions"

    enum Capability { case page, native(String), logic }
    var method: String { "testKoaWebview" + rawValue }
    var capability: Capability {
        switch self {
        case .placeInset: return .native("native pane chrome")
        case .quoteSelection: return .native("native selection bridge")
        case .selectAllCopiesTheWholeTranscript: return .native("native selection and pasteboard")
        case .findSkippedHistory: return .native("native find")
        case .focusBorderTranscript: return .native("app chrome")
        case .composerFocus: return .native("native focus and keyboard routing")
        case .threadsModes: return .native("native keyboard routing")
        case .previewHover: return .native("native preview integration")
        case .scrollbarJumpMountsHistory: return .logic
        default: return .page
        }
    }
}
