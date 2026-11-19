---
layout: ../../layouts/Docs.astro
title: Install
group: Start
order: 1
---

Kido has three parts, and each part is one Homebrew package. This page is a sample that shows each element of the documentation layout.

## Packages

| Package | Command | Contents |
| --- | --- | --- |
| ko | `brew install andreypopp/tap/ko` | The server and the terminal client |
| Kido.app | `brew install --cask andreypopp/tap/kido-app` | The macOS client |
| koa | `brew install andreypopp/tap/koa` | The pi harness |

> **Note.** A note is a pale plane with slanted edges. Use it for a fact that the reader must not miss.

## Start the server

Install ko, then start it:

```sh
brew install andreypopp/tap/ko
ko
```

The first `ko` starts the server and attaches the terminal client to it.

### Inside a pane

A list looks like this:

- Sessions hold windows.
- Windows hold panes.
- A pane is a split or a float.

A numbered list looks like this:

1. Install the package.
2. Start the server.
3. Open Kido.app.

### A longer code block

```ts
const response = await fetch('http://localhost/panes', { method: 'POST' });
const pane = await response.json(); // the new pane
console.log(pane.id);
```

## Next steps

Read [Quick start](../quick-start/) for the first session.
