# Design Notes – A1-Text

## Purpose of this document

This document explains the design decisions behind **A1-Text**.
It is not a user manual and not a roadmap.

Its goal is to clarify **why** certain choices were made, especially where they differ from mainstream word processors.

---

## Core idea: intervene while typing, not after

Most modern word processors treat text as something to be corrected *after* it has been written.
Rules are applied post‑hoc: grammar checks, autocorrect passes, formatting steps.

A1-Text takes a different approach:

> **Text behavior is shaped at the moment of typing.**

This means:

* reacting to key events instead of reprocessing the document
* using local context (previous characters, punctuation, dialogue markers)
* prioritizing typing flow over correctness after the fact

This approach is closer to classic Amiga-era editors than to modern office suites.

---

## Why plain text (.txt) only

A1-Text intentionally works only with plain text files.

Reasons:

* avoid coupling writing to formatting
* keep files future-proof and portable
* remove layout concerns from the writing phase

Formatting and publishing are considered **separate steps**, handled by other tools.

---

## Intelligent punctuation as a first-class feature

Punctuation handling is not implemented as a cosmetic convenience.
It is a core design element.

Examples:

* automatic space insertion after punctuation
* capitalization only when linguistically appropriate
* removal of automatically inserted spaces when `Enter` is pressed after a sentence or dialogue closure

This behavior is designed to support **narrative writing**, especially dialogue, without interrupting the author’s rhythm.

This approach was directly inspired by **C1-Text for Amiga**, whose handling of punctuation and typing flow demonstrated that small, context-aware interventions can significantly improve the writing experience.

---

## Why key-level interception

Instead of manipulating the text buffer after changes, A1-Text intercepts key events.

Advantages:

* predictable behavior
* no visual flicker or corrective jumps
* fine-grained control over context

This also allows features such as:

* dialogue-aware behavior
* conditional space removal
* controlled word substitution on explicit triggers (e.g. space key)

---

## Visible line breaks

Displaying line break symbols is a deliberate choice.

It reinforces the idea that:

* text structure matters
* paragraph boundaries are intentional

This feature can be distracting for some users, but is valuable during drafting and revision.

---

## Word substitution and completion

Word substitution is triggered explicitly by the space key.

This avoids:

* aggressive or unexpected replacements
* mid-word transformations

Word completion is designed to be:

* optional
* dismissible
* non-intrusive

The system should *assist*, not override, the writer.

---

## Grammar checking

Grammar checking is delegated to **LanguageTool**, run locally.

Reasons:

* language expertise is externalized
* no tight coupling to grammar rules
* respect for user privacy

Grammar feedback is advisory, not authoritative.

---

## Optional AI features

AI-assisted features are optional and explicitly disabled by default.

Design principles:

* no background AI processing
* no automatic rewriting
* user-controlled invocation only

The editor remains fully usable without any AI components.

---

## Why Ruby and GTK4

Ruby was chosen for:

* expressiveness
* fast iteration
* suitability for experimental tools

GTK4 was chosen for:

* native Linux integration
* modern rendering
* long-term platform stability

Performance is considered *sufficient* for the intended scope.

---

## Project scope and expectations

A1-Text is a personal side project.

There is:

* no fixed roadmap
* no guarantee of feature parity with mainstream editors
* no commitment to frequent updates

Design coherence is prioritized over feature accumulation.

---

## Non-goals

A1-Text does **not** aim to:

* replace LibreOffice or Microsoft Word
* provide WYSIWYG layout
* support collaborative editing
* act as a publishing tool

It exists to explore a different way of thinking about typing and text.

---

## Final note

A1-Text is intentionally opinionated.

Some choices may feel unconventional.
They are the result of prioritizing **writing flow, control, and intentionality** over universality.

Feedback is welcome, especially when it engages with these design goals rather than opposing them.
