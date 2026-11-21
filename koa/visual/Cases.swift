enum KoaSelection {
    case all
    case captures(Set<String>)
}

enum KoaFixture: String, CaseIterable {
    case dots = "Dots"
    case runStepsTransitions = "RunStepsTransitions"
    case scrollbarJumpMountsHistory = "ScrollbarJumpMountsHistory"
    case bangCompletion = "BangCompletion"
    case bang = "Bang"
    case composerFootResponsive = "ComposerFootResponsive"
    case composerFootStates = "ComposerFootStates"
    case composerStateGeometryWide = "ComposerStateGeometryWide"
    case composerStateGeometryNarrow = "ComposerStateGeometryNarrow"
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
    case threads = "Threads"
    case threadsFilter = "ThreadsFilter"
    case threadsFilterPanel = "ThreadsFilterPanel"
    case agents = "Agents"
    case subagentView = "SubagentView"
    case viewBar = "ViewBar"
    case jobs = "Jobs"
    case lightbox = "Lightbox"
    case paths = "Paths"
    case media = "Media"
    case attachments = "Attachments"
    case userMarkdown = "UserMarkdown"
    case reveal = "Reveal"
    case thinkingMarkdown = "ThinkingMarkdown"
    case composerMarkdown = "ComposerMarkdown"
    case questions = "Questions"
    case completion = "Completion"
    case sessions = "Sessions"

    enum Capture { case geometry, light, dark, both }
    var captures: [String: Capture] {
        switch self {
        case .bangCompletion:
            return ["bang-tab": .light, "narrow-bang-tab-cap": .light, "bang-tab-none": .light, "bang-tab-cap": .geometry, "narrow-bang-tab": .geometry, "narrow-bang-tab-none": .geometry, "bang-tab-pending": .geometry, "narrow-bang-tab-pending": .geometry]
        case .bang:
            return ["bang": .light, "bang2": .light, "bang-attachments": .light, "bang-runs": .light, "bang-done": .light, "bang-error": .light, "bang-cancelled": .light, "bang-truncated": .light, "bang-running": .light, "bang-busy": .light, "narrow-bang": .geometry, "narrow-bang2": .geometry, "narrow-bang-attachments": .geometry, "narrow-bang-runs": .geometry, "narrow-bang-done": .geometry, "narrow-bang-error": .geometry, "narrow-bang-cancelled": .geometry, "narrow-bang-truncated": .geometry, "bang-quiet": .geometry, "narrow-bang-quiet": .geometry, "narrow-bang-running": .geometry, "bang-typing": .geometry, "narrow-bang-typing": .geometry, "narrow-bang-busy": .geometry, "bang-completed": .geometry, "narrow-bang-completed": .geometry]
        case .composerFootResponsive:
            return ["foot-responsive-674-idle": .light, "foot-responsive-554-idle": .light, "foot-responsive-374-idle": .light, "foot-responsive-250-idle": .light, "foot-responsive-190-idle": .light, "foot-responsive-374-picker": .light, "foot-responsive-554-cwd": .light, "foot-responsive-420-long-model": .light, "foot-responsive-674-run": .geometry, "foot-responsive-674-completing": .geometry, "foot-responsive-674-working": .geometry, "foot-responsive-674-cwd": .geometry, "foot-responsive-554-run": .geometry, "foot-responsive-554-completing": .geometry, "foot-responsive-554-working": .geometry, "foot-responsive-374-run": .geometry, "foot-responsive-374-completing": .geometry, "foot-responsive-374-working": .geometry, "foot-responsive-374-cwd": .geometry, "foot-responsive-250-run": .geometry, "foot-responsive-250-completing": .geometry, "foot-responsive-250-working": .geometry, "foot-responsive-250-cwd": .geometry, "foot-responsive-190-run": .geometry, "foot-responsive-190-completing": .geometry, "foot-responsive-190-working": .geometry, "foot-responsive-190-cwd": .geometry, "foot-responsive-674-long-model": .geometry]
        case .composerFootStates:
            return ["foot-idle": .light, "foot-working": .light, "foot-editing": .light, "foot-narrow": .light, "foot-extras": .light, "narrow-foot-idle": .geometry, "narrow-foot-working": .geometry, "foot-waiting": .geometry, "narrow-foot-waiting": .geometry, "narrow-foot-editing": .geometry, "foot-exited": .geometry, "narrow-foot-exited": .geometry, "foot-picker": .geometry, "narrow-foot-picker": .geometry, "foot-toast": .geometry, "narrow-foot-toast": .geometry, "foot-toast-err": .geometry, "narrow-foot-toast-err": .geometry, "narrow-foot-narrow": .geometry, "narrow-foot-extras": .geometry]
        case .composerStateGeometryWide:
            return ["geometry": .geometry]
        case .composerStateGeometryNarrow:
            return ["geometry": .geometry]
        case .commandsNarrow:
            return ["narrow-commands-session-closed": .light, "narrow-commands-session-open": .dark, "narrow-commands-compacting": .light, "narrow-commands-compact-failed": .light, "narrow-commands-export-open": .light, "narrow-commands-copy": .geometry, "narrow-commands-export": .geometry, "narrow-commands-refused": .geometry, "narrow-commands-compacted-open": .geometry, "narrow-commands-compact-cancelled": .geometry, "narrow-commands-popup": .geometry]
        case .mockupStates:
            return ["user-well": .both, "stream": .both, "lines": .light, "details": .both]
        case .notices:
            return ["notices-closed": .light, "notices-open": .light, "narrow-notices-closed": .geometry, "narrow-notices-open": .geometry]
        case .latest:
            return ["latest-divider": .light, "latest-new": .both, "narrow-latest-divider": .geometry, "narrow-latest-new": .geometry]
        case .errorState:
            return ["error": .light]
        case .shortStates:
            return ["idle": .light, "composer-multi": .light, "composer-working": .light, "run-running": .light, "run-done": .light]
        case .narrowStates:
            return ["narrow-stream": .both, "narrow-details": .light]
        case .dialogs:
            return ["dialog-select": .light, "dialog-editor": .light]
        case .controls:
            return ["queue": .both, "picker-model": .light, "picker-thinking": .light, "toast-info": .light, "toast-warn": .light, "toast-error": .light]
        case .narrowControls:
            return ["narrow-queue": .both, "narrow-picker-model": .light, "narrow-toast-warn": .geometry]
        case .exit:
            return ["times": .light]
        case .failed:
            return ["exited": .light, "narrow-exited": .geometry]
        case .threads:
            return ["threads-many": .both, "threads-many-narrow": .both, "threads-marks": .both, "threads-marks-narrow": .geometry, "threads-two": .geometry]
        case .threadsFilter:
            return ["threads-filter": .light, "threads-filter-narrow": .geometry]
        case .threadsFilterPanel:
            return ["threads-filter-panel": .both]
        case .agents:
            return ["agents-out": .light, "agents-failed": .light, "agents-in": .light, "agents-jobs": .light, "agents-fold-a": .light, "agents-fold-b": .light, "agents-tools": .light, "narrow-agents-out": .light, "narrow-agents-failed": .geometry, "narrow-agents-jobs": .geometry, "narrow-agents-in": .geometry, "narrow-agents-fold-a": .geometry, "narrow-agents-fold-b": .geometry, "narrow-agents-tools": .geometry]
        case .subagentView:
            return ["subagent-child": .both, "subagent-working": .geometry, "narrow-subagent-working": .geometry, "subagent-warning": .geometry, "narrow-subagent-warning": .geometry, "subagent-grandchild": .geometry, "narrow-subagent-grandchild": .geometry, "subagent-root": .geometry, "narrow-subagent-root": .geometry, "narrow-subagent-child": .geometry]
        case .viewBar:
            return ["viewbar-overflow": .both, "viewbar-menu": .light, "narrow-viewbar-menu": .light, "viewbar-return": .geometry, "narrow-viewbar-overflow": .geometry, "narrow-viewbar-return": .geometry]
        case .jobs:
            return ["job-running": .both, "narrow-job-running": .light, "job-ended": .light, "job-service": .light]
        case .lightbox:
            return ["media-lightbox": .light]
        case .paths:
            return ["path-links": .light, "path-warning": .geometry]
        case .media:
            return ["media-read-image": .light, "media-user-images": .both, "media-image-gone": .both, "narrow-media-user-images": .light, "narrow-media-read-image": .geometry, "narrow-media-image-gone": .geometry]
        case .attachments:
            return ["media-chips": .light, "media-drop": .light, "media-folder": .light, "media-queue": .both, "media-sent": .both, "narrow-media-chips": .light, "narrow-media-sent": .light, "narrow-media-queue": .geometry, "narrow-media-drop": .geometry, "narrow-media-folder": .geometry]
        case .userMarkdown:
            return ["user-markdown": .both, "narrow-user-markdown": .light, "user-quote": .both, "narrow-user-quote": .light, "user-code": .both, "narrow-user-code": .light]
        case .reveal:
            return ["reveal-fold": .light]
        case .thinkingMarkdown:
            return ["thinking-markdown": .light, "narrow-thinking-markdown": .light]
        case .composerMarkdown:
            return ["composer-markdown": .light, "composer-markdown-code": .light]
        case .questions:
            return ["questions-reply": .light, "questions-ordered": .dark, "narrow-questions-reply": .light, "questions-answered": .geometry, "narrow-questions-answered": .geometry, "narrow-questions-ordered": .geometry]
        case .completion:
            return ["complete-slash-filter": .light, "complete-at-agents": .light, "complete-at-files": .light, "narrow-complete-slash-all": .light, "complete-slash-all": .geometry, "complete-at-mid": .geometry, "complete-none": .geometry, "narrow-complete-slash-filter": .geometry, "narrow-complete-at-agents": .geometry, "narrow-complete-at-files": .geometry, "narrow-complete-at-mid": .geometry, "narrow-complete-none": .geometry]
        case .sessions:
            return ["sessions-pick": .both, "sessions-empty": .both, "sessions-loading": .light, "sessions-confirm": .light, "narrow-sessions-pick": .light, "narrow-sessions-confirm": .light, "sessions-all": .geometry, "narrow-sessions-all": .geometry, "sessions-filtered": .geometry, "narrow-sessions-filtered": .geometry, "narrow-sessions-empty": .geometry, "sessions-no-match": .geometry, "narrow-sessions-no-match": .geometry, "narrow-sessions-loading": .geometry, "sessions-after": .geometry, "narrow-sessions-after": .geometry, "sessions-new": .geometry, "narrow-sessions-new": .geometry, "sessions-confirm-bash": .geometry, "narrow-sessions-confirm-bash": .geometry]
        default: return [:]
        }
    }

    var method: String { "testKoaWebview" + rawValue }

}
