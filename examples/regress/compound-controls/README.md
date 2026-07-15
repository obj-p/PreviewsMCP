# Compound Controls and Accessibility

This view puts controls into layouts where an accessibility frame is often
larger than the physical hit target:

- a standard row-style `Toggle`;
- a trailing hidden-label toggle inside a combined row;
- two controls with the same visible label but distinct identifiers;
- a disabled toggle;
- a nested button with a custom content shape;
- a slider, menu, picker, text field, disclosure group, and off-screen control.

Start the iOS preview, fetch interactable elements, and record each element's
identifier/path, traits, value, enabled state, frame, and activation point. The
center of `trailing-toggle-row` intentionally lands toward the row label rather
than the visual switch. Raw coordinate touch may no-op there; semantic
activation should toggle exactly the identified control and acknowledge the
state change.

The duplicate labels make label-only matching observably ambiguous. The
disabled and off-screen controls make successful dispatch distinct from an
observed value change.

The transformed preview adds scaling and rotation so accessibility frames and
activation points can be compared against the simulator's physical coordinate
space instead of assuming an identity transform.
