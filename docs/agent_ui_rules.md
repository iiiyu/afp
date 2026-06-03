# Agent UI Rules

## Purpose

This document holds the frontend styling and UI quality guidance that was previously in `AGENTS.md`.
Read this file before changing CSS, JavaScript hooks, layouts, or visual presentation.

## CSS and JS rules

- Use Tailwind CSS classes and custom CSS rules for the interface.
- Keep the Tailwind v4 import format in `assets/css/app.css`:

```css
@import "tailwindcss" source(none);
@source "../css";
@source "../js";
@source "../../lib/afp_web";
```

- Never use `@apply`.
- Do not introduce daisyUI.
- Only `app.js` and `app.css` bundles are supported out of the box.
- Do not reference external vendor scripts or styles directly from layouts.
- Import browser dependencies into `app.js` or `app.css`.
- Never write inline `<script>` tags inside templates.

## UI quality rules

- Produce polished UI with strong usability and visual quality.
- Use subtle micro-interactions such as hover and transition polish where appropriate.
- Maintain clean typography, spacing, and layout balance.
- Add thoughtful loading, hover, and transition details rather than bare functional markup.

## Practical interpretation

- Prefer project-consistent Tailwind composition over ad hoc raw CSS blocks.
- If a screen already has a visual language, preserve it instead of restyling everything.
- If a change is backend-focused, avoid incidental visual churn.
