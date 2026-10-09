# Program icon concepts

Planning previews requested by Bob: an adult V-taper man and an adult slim, curvy woman, wearing workout clothing. Both programs remain available to anyone; these icons are decorative, not demographic inputs or promised outcomes.

SVG source is normalized to a 96×128 viewBox with round 2.7-unit strokes. PNG thumbnails are local vector-rendered previews. Runtime implementation translates the paths into native SwiftUI Shape geometry, tints them with foregroundStyle, and hides the decorative image from VoiceOver while labeling each program button fully. Source vectors preserve scale and transparency; preview thumbnails use white backgrounds.

- upper-body-emphasis.svg / upper-body-emphasis.svg.png
- whole-body-glute-emphasis.svg / whole-body-glute-emphasis.svg.png

Reviewed the rendered full figures. Check the runtime rendering at 44 points, both color schemes and largest Dynamic Type during Task5; the local concept preview is not runtime UI verification.

Bob approved the Whole-body, glute emphasis revision on October 9, 2026. It preserves the front-facing head, arms, and sports top while using rounded hips spanning x33–63 and softly tapered legs approximately 8–9 units wide. The matching PNG is the approved 320×440 white-background preview, rendered from the SVG with a figure about 215 pixels high; it is a design reference, not a runtime asset or runtime UI verification. Native SwiftUI paths match the approved source geometry.
