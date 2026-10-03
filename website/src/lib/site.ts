export const github = 'https://github.com/andreypopp/kido';
export const install = 'brew install andreypopp/tap/kido';
export const title = 'kido — An opinionated tmux+pi workflow';
export const description = 'An opinionated tmux+pi workflow: sidebar, subagents and async bash and monitor processes.';
export const socialImage = 'https://kido.tools/media/tmux.jpg';
export const url = (path = '') => `${import.meta.env.BASE_URL.replace(/\/$/, '')}/${path}`;
export const mediaLabels = {
  tmux: 'Interactive sidebar showing tmux sessions, windows, panes, and shell and agent status, including shells over ssh',
  subagents: 'A pi extension spawning subagents as tmux windows to communicate and collaborate',
  async: 'A pi extension spawning async bash processes and monitors with real-time execution status',
};
export const media = Object.fromEntries(
  Object.keys(mediaLabels).map((name) => [
    name,
    {
      mp4: url(`media/${name}.mp4`),
      webm: url(`media/${name}.webm`),
      poster: url(`media/${name}.jpg`),
      mobile: {
        mp4: url(`media/${name}-mobile.mp4`),
        webm: url(`media/${name}-mobile.webm`),
        poster: url(`media/${name}-mobile.jpg`),
      },
    },
  ]),
);
