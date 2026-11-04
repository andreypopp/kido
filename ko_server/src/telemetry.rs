use crate::program_status::Set;
use crate::protocol::{Foreground, Progress};
use ko_pane_wire::frame::PromptStep;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CommandRun {
    pub(crate) started_at: u64,
    pub(crate) line: String,
    pub(crate) running: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct LastExit {
    pub(crate) code: i32,
    pub(crate) at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Prompt {
    pub(crate) step: PromptStep,
    pub(crate) exit: Option<i32>,
    pub(crate) at: u64,
    pub(crate) command: String,
}

#[derive(Debug, Default)]
pub(crate) struct Telemetry {
    pub(crate) last_prompt: Option<u64>,
    pub(crate) command: Option<CommandRun>,
    pub(crate) last_exit: Option<LastExit>,
    pub(crate) records: Set,
    pub(crate) foreground: Option<Foreground>,
    pub(crate) alternate: bool,
    pub(crate) progress: Option<Progress>,
    pub(crate) in_runtime: bool,
}

impl Telemetry {
    pub(crate) fn prompt(&mut self, prompt: Prompt) {
        match prompt.step {
            PromptStep::Start => {
                self.last_prompt = Some(prompt.at);
                if let Some(command) = &mut self.command {
                    command.running = false;
                }
                self.records.prompt_start();
            }
            PromptStep::OutputStart => {
                self.command = Some(CommandRun {
                    started_at: prompt.at,
                    line: prompt.command,
                    running: true,
                });
                self.last_exit = None;
            }
            PromptStep::End => {
                if let Some(command) = &mut self.command {
                    command.running = false;
                }
                if let Some(code) = prompt.exit {
                    self.last_exit = Some(LastExit {
                        code,
                        at: prompt.at,
                    });
                }
            }
        }
    }

    pub(crate) fn foreground(&mut self, foreground: Foreground) -> bool {
        let changed = self.foreground.as_ref() != Some(&foreground);
        self.foreground = Some(foreground);
        changed
    }

    pub(crate) fn set_alternate(&mut self, on: bool) -> bool {
        std::mem::replace(&mut self.alternate, on) != on
    }

    pub(crate) fn set_progress(&mut self, progress: Option<Progress>) -> bool {
        let changed = self.progress != progress;
        self.progress = progress;
        changed
    }

    pub(crate) fn status_foreground(&self) -> Option<&Foreground> {
        self.foreground.as_ref().filter(|_| !self.in_runtime)
    }

    pub(crate) fn foreground_name(&self) -> &str {
        self.status_foreground()
            .map_or("", |foreground| foreground.name.as_str())
    }
}
