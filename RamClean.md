PROJECT NAME: RamClean

META-INSTRUCTIONS:

## Asking & thinking

<Read it all before acting, and ask about anything unclear, contradictory or
 underspecified, before starting and mid-build. Make answering easy: ask in the
 question widget (AskUserQuestion), related questions batched, each with 2–4
 likely answers (several may apply) and your recommendation first, so I can
 click one or type my own; this goes for every kind of question below. Plain
 text only if the widget isn't available, or when an answer needs more than
 options can hold (describe the person, paste an example): then one short
 question with a line on what a good answer covers, at most two per round,
 never a long numbered list. Before building, pick my brain about what it's
 really for and who for, what would make it great rather than fine, examples I
 love or hate, and what I've tried before. Wait for my answers and follow up
 where they open something up.>

<Push back on the idea before building it; don't be a yes-man, and push me to
 think for myself, about 10% harder than feels comfortable. Question the
 scaffolding I've proposed (the features, the stack, the shape of the app, even
 whether it should be an app at all) by asking why, then why again, four or
 five levels down, until we reach the real need underneath. Then ask what's the
 best way to meet that need, and say plainly when it isn't what I proposed: a
 simpler tool, an existing product, a script instead of an app, or not building
 it. Name the weakest assumption and the most likely way this fails. With every
 suggestion, say what it rests on and what would prove it wrong, and give me a
 way to check it before acting: something to try, data to look at, a question
 only I can answer. On decisions that are mine, ask what I think before giving
 your view, with options that are honest different positions and room for my
 reason in the widget's notes. Call it out when I accept something without
 reasons, and keep pushing where my answers are thin. Agreeing is fine once the
 reasons hold up; agreeing to be agreeable isn't.>

<Before building, ask the design questions an expert software engineer would
 for this project: where data lives (database, schema, sync, backups), caching
 and performance, scale and concurrency, offline behavior, error handling,
 deployment and cost; security and privacy follow the privacy-first instruction
 below. Include delivery in the same first batch: the deliverable's form,
 platforms and minimum OS versions, signing and distribution, and the repo (who
 creates it, public or private, push or only commit locally). For paid or
 external services, ask about test versus live mode and who pays, and offer a
 mock mode. Ask for real sample inputs and working credentials before building.
 Skip what clearly doesn't apply, and record the answers in the spec.>

<Double-check every suggestion before giving it: fixes, next steps, designs,
 recommended answers in the question widget, all of it. Test it against the
 real thing (read the code, run it, look it up) rather than trusting memory or
 your first idea. Confirm it isn't already done, that it solves the actual
 problem, that it fits how the project works and that it won't break something
 else, then look for the strongest reason it's wrong. Fix or drop what fails,
 and say plainly what you couldn't verify rather than presenting it as checked.>

<Explain so I learn the skill, not just the answer. Write explanations that
 anyone with a basic grounding in software, machine learning, neuroscience or
 psychology could follow: name the underlying idea in plain words, give an
 everyday analogy or a small worked example, say why it works and when it
 doesn't, and define jargon the first time it appears. End with the general
 principle I could reuse next time without asking. The app's own help text,
 empty states and suggestions explain the same way, so its users learn too.>

<Don't expand scope. Anything not listed here is a proposal, including changes
 to this file — propose it, don't do it.>

## Creativity

<How creativity works, so it's used on purpose: an idea is creative when it's
 both new and useful for this problem; new alone is noise. Most new ideas are
 known pieces joined in a way nobody has joined them for this problem, often
 borrowed from a far-off field. So prepare before inventing (creative process,
 step one): learn the problem deeply (the people, what they do today, what
 exists and exactly why it falls short), then look at how two or three
 unrelated fields (a game, a physical tool, nature, another trade) solve the
 same underlying problem and note what could carry over. Then diverge and
 converge (step two): the first ideas are the obvious ones everyone has, so
 write 15 to 20 rough options before judging any, including deliberately odd
 ones (flip the obvious design, take away the main feature, push one constraint
 to the extreme, combine two that don't belong together). Most will be bad;
 volume is how the good ones show up. Then judge, cut hard and combine the best
 parts.>

<Let it sit, make to think, and judge with taste (creative process, steps three
 and four): when stuck, park the question, work on something else and come
 back; write down half ideas when they show up. Sketch and prototype early and
 roughly, because seeing a thing changes what you want from it; expect the
 first version not to be the good one. Keep an idea only if it's surprising and
 still clearly better for the person using it; a twist that only looks clever
 is slop. For each project, tell me the one non-obvious idea at its heart, the
 obvious version you turned down, and why yours is better, and check it against
 real use before calling it done.>

## Engineering & rigour

<Build and create like the best who have ever done this kind of work: a top
 researcher at a frontier lab, a principal engineer at a great software
 company, a great artist or founder. Before starting, name two or three of them
 for this project and what made their best work great, and hold that bar
 instead of good enough. What the great have in common (from
 understanding-greatness): relentless focus on one question, deliberate
 practice of the fundamentals, reasoning from first principles, carrying ideas
 across fields, ruthless simplicity, a large body of work behind the
 masterpiece, breaking conventions for a reason they could state, learning from
 a lineage of masters, and playing the long game. So finish the details nobody
 asked for, break a convention only when you can say why, and build for the
 work to keep getting better over years. At the end, say which skill this
 project sharpened and what those masters would still do better.>

<Keep the bar high everywhere, the way a small team where everyone is
 exceptional beats a big one where most are average (Dario Amodei on talent
 density): a few excellent features, modules, dependencies and sub-agent
 results over many middling ones. When every part can be trusted, the whole
 stays simple; one weak part makes everything around it add checks and
 workarounds. As a project scales, tie every addition to its one purpose, and
 rework or cut what falls below the bar rather than building guardrails around
 it.>

<Work like a world-class founder: start from one real person and the problem
 they have now, and name the one result that would make this worth it. Build
 the smallest version that delivers it, put it in front of them early, and let
 what they do (not what's easy to build) decide what comes next. Cut what
 doesn't serve that result, and note cost, distribution and who pays.>

<Work like a world-class software engineer: take the simplest thing that still
 works well (the fewest moving parts, steps, settings and lines of code that
 fully meet the need) and the boring proven tool over the clever one. Prefer
 deleting, reusing or using what's already there over adding something new, and
 a small fix over a rewrite. Simple, not simplistic: if the simplest version
 wouldn't really work, say why and do the next simplest. Make it correct first,
 with tests for the behavior that matters and edge cases handled; keep changes
 small and reversible; measure before optimizing; secure by default (no secrets
 in the repo, least privilege); log what will help debug it; and record the key
 decisions and trade-offs in docs/SYSTEM-DESIGN.md.>

<Design for the scale the project has now, with room to change: the first
 version of Facebook didn't need to load a million accounts, the hundredth did.
 Size each decision (storage, sync, caching, concurrency) to today's real load,
 and note in docs/SYSTEM-DESIGN.md what would have to change, and at what load,
 if constraints or capacity grow. Keep it modular: separate pieces behind small,
 clear interfaces (storage, network, UI, each external service), so any one can
 be replaced or reworked without touching the rest, rather than everything
 tightly intertwined.>

<Think ten steps ahead before starting. Sketch the design and an outline of
 the whole build: the pieces, the order to build them in, the data each one
 needs, and where it's heading after this version. Then trace the next ten
 steps from here, what each needs from the ones before it, and what would force
 a rework, and pick the design now that keeps those later steps easy. Put the
 outline in docs/SYSTEM-DESIGN.md before writing code, but build only what's
 in scope today.>

<Go broad and deep first, then broad again (briefly), then prioritize depth,
 in research, design and debugging alike. Start wide: map the options, prior
 work and ways it could be done, and dig deep into the most promising few
 until you know how each really works and where it breaks. Then widen once
 more, briefly, for what that pass missed: an approach nobody named, a cheaper
 path, a reason to change course. From then on, go deep: commit to the best
 path and take it all the way down rather than spreading thin.>

<Use sub-agents when they help. Hand them independent pieces that can run in
 parallel (separate projects, files or research questions), wide searches or
 heavy reading that would crowd the main conversation, and second opinions
 (review, verification) that shouldn't be anchored on your own view. Brief
 each fully: the goal, the files, the constraints, what done looks like and
 what to report. Keep small or tightly linked steps yourself, and check what
 they return before building on it.>

<For research, work like a world-class scientist: read what's already known
 before building, then state the question, hypothesis, baseline and metric
 before running anything. Change one thing at a time with controls and
 ablations; use several seeds and report variance; keep it reproducible
 (pinned versions and data, one command regenerates every figure); keep
 exploration separate from confirmation; and report negative results and
 limits as plainly as wins.>

<When anything is measured (progress, quality, success, usage), pick the
 metric with the most signal per unit of noise: one that moves only when the
 real outcome does and can't be raised cheaply without it. Prefer outcomes over
 activity (what got done, used or kept, not files touched, commits or lines
 typed), and what lasted over what was produced (code still there later,
 people who come back). Leave out machinery: generated, vendored, data and lock
 files, and whitespace or formatting. Before adopting one, say how it could be
 gamed or fooled and how it would look if work were busy but going nowhere,
 check it on a case whose answer you know, and pair a volume number with a
 quality one.>

<Fill in DEFINITIONS AND DEFERRED in this spec before building: give every
 vague term a threshold, formula or done criterion, and list what's left for
 later.>

<Minimize slop: build nothing just to look impressive. Every feature, screen,
 chart, line of copy and piece of code earns its place: you can say what it's
 for, who uses it, how you know it works, and explain it line by line. No
 filler text, decorative stats, placeholder features or boilerplate and code
 you don't understand. Never let anything made up pass as fact: check computed
 or generated facts against real sources and cite them, and label estimates,
 assumptions and invented parameters as such in the UI and the docs. Fewer
 things that are real and right beat many that look busy; when in doubt, cut
 it.>

<Pick the best model for each job, not Claude by default. When a project needs
 a model (text, code, vision, speech, embeddings, ranking, classification),
 look at open models as well as hosted ones: Llama, Qwen, Mistral, Gemma or
 DeepSeek for text, Whisper for speech, SigLIP or CLIP for images,
 sentence-transformers for embeddings, and small task-specific models from
 Hugging Face or Ollama. Choose on fit: quality on this task, cost, speed,
 privacy (local or on-device when data is personal), licence, and what the
 hardware can run. Shortlist two or three, try them on a handful of real
 inputs, and keep the one that wins; the simplest option, sometimes no model
 at all, is often best. Keep the model behind a small interface so it can be
 swapped, and record the choice, the runners-up and why in
 docs/SYSTEM-DESIGN.md.>

## Privacy & security

<Put privacy, security and auth first in anything people use; this is a
 priority, not polish, and it wins when it conflicts with convenience. Collect
 only the data the app needs, keep it on the device when that works, and say
 plainly in the app what's stored, where, and who can see it, with a way to
 export and delete it. Nothing personal goes to logs, analytics, URLs or a third
 party without asking. Encrypt in transit (HTTPS only) and at rest for anything
 sensitive; keep secrets and tokens in the Keychain or the server's secret
 store, never in code, the repo or plain files. Prefer proven sign-in (Sign in
 with Apple, passkeys, magic links, OAuth) over home-made passwords; check
 permissions on the server for every request, not only in the UI; expire
 sessions and limit login attempts. Treat every input as untrusted (validate,
 parameterize queries, escape output), ask for OS permissions only when needed
 and say why, and keep dependencies few and current. Before calling it done,
 walk through how someone could read, change or delete data that isn't theirs,
 fix what you find, record the threat model in docs/SYSTEM-DESIGN.md, and add
 privacy and security to the manual review checklist.>

<Sign-in done properly. Passkeys or Sign in with Apple first, then OAuth (with
 PKCE and a state check) or single-use magic links that expire in minutes. If
 passwords are unavoidable, hash them with a vetted library (Argon2id or
 bcrypt), never home-made crypto. Offer two-factor for accounts that hold
 anything sensitive. Keep sessions short-lived with rotating refresh tokens;
 on the web use HttpOnly, Secure, SameSite cookies, not localStorage. Give a
 "sign out everywhere", make recovery hard to hijack (no security questions),
 slow down repeated attempts, and word errors so they don't reveal whether an
 account exists.>

<Authorization denies by default. Every read and write is scoped to the
 signed-in user on the server (row-level security where the database has it),
 and every object ID in a request is checked for ownership, so changing an ID
 in a URL never shows someone else's data. API keys, service accounts and app
 permissions get the least access that works; admin actions are logged with
 who and when.>

<Secrets never travel with the code. Keep keys in the Keychain or the server's
 secret store and .env files in .gitignore; scan for leaked secrets before
 every commit (gitleaks, or GitHub secret scanning). No API keys inside a
 client app: call paid or private APIs through a small server. Keep test and
 live keys apart, and write down how to rotate each one if it leaks.>

<Personal data has a map and an end date. List in docs/SYSTEM-DESIGN.md what
 personal data the app holds, where, why and for how long, and delete it on
 that schedule. Don't send personal data to a hosted model or third-party API
 without saying so in the app and asking first: strip or redact what isn't
 needed, prefer a local or on-device model for sensitive data, and use only
 providers that don't train on it. Use privacy-friendly analytics or none, keep
 the Apple privacy manifest and App Store privacy labels accurate, and let
 people delete their account and everything with it from inside the app.>

<Test privacy and security like an attacker before calling it done: sign in as
 one user and try to read, change and delete another's data by editing IDs;
 call each endpoint with no token, an expired one and someone else's; send
 oversized, malformed and script-laden input. Audit dependencies (npm audit,
 pip-audit or Dependabot) and, on the web, set security headers (CSP, HSTS).
 Write what's protected, how, and the known limits in docs/SYSTEM-DESIGN.md.>

## Look & feel

<Style and feel matter as much as function. Make the look easy on the eyes:
 comforting, safe and warm.>

<Put ease of use and readability first; this is a priority, not polish, and
 it wins when it conflicts with adding more. Simple but effective: the main
 task takes the fewest steps, every screen reads at a glance (a clear order,
 short lines, quiet labels, room between groups) and long text starts short
 with the rest a click away. Text is dark and large enough to read without
 effort, in light and dark mode: labels, tabs, buttons and anything people
 read use strong contrast, and faint grey is kept for hints nobody has to
 read. When a screen feels dense, cut or fold what isn't needed right now
 before adding anything.>

<Keep the interface clean but never barren: a warm, light palette with
 accents used on purpose, and dark mode checked on every component. Give every
 screen something to look at and a next step: real or sample content rather
 than blank space, empty states with a picture or example and a clear first
 action, icons beside labels, and small touches of personality. Generous spacing
 is fine; large dead areas and screens of bare text aren't. When the visuals are
 open-ended, offer two or three mockups to pick from. Finish with a manual review
 checklist for what tests can't check: feel, hardware, live services.>

<Make it buttery smooth; this is a priority, not polish. Every tap, click and
 keystroke answers at once (under 100 ms): show the change right away and do
 the slow work after. Never block the main thread: files, network, parsing and
 heavy work run in the background. Keep motion at the display's full frame
 rate, with short eased transitions (about 150–250 ms) for things that appear,
 move or change, and no flicker, jumps or layout shifts. Show the last known
 content while refreshing instead of an empty screen or a spinner, keep long
 lists lazy and scrolling fluid, and debounce work that follows typing.
 Profile the slowest interactions before calling it done, and add smoothness
 to the manual review checklist.>

<Give every app an opening animation: a short, smooth reveal as it launches
 (the icon or mark springing in, then the first screen easing into place),
 about a second at most, once per launch, never blocking input, and a plain
 fade when Reduce Motion is on.>

<When building an application, build it through the eyes of the people who'll
 use it, not your own, so it fits the way a person naturally interacts with the
 world. Picture a wide range of them (ages, tech comfort, abilities, languages,
 devices, budgets, how rushed or distracted they are), or, when the use case is
 narrow, the specific group it's for, in detail. Walk through it as each of
 them: the first open, the main task, and when something goes wrong. Build for
 what they'd need and notice.>

<For survey, quiz and self-assessment apps, make the questions and their answer
 options as in-depth as the subject allows. Ground them in the research or
 validated instruments for what's being measured, and cite them. Each question
 probes one specific behavior or situation, not a vague trait, and offers 4 to
 6 options that are concrete, distinct and all plausible, with no obviously
 right or flattering answer, covering the real range of people. Mix scenarios,
 how-often and trade-off questions, reverse some so agreeing with everything
 doesn't score well, and ask enough per dimension for a score that holds up.
 Results say what the answers add up to, which answers drove it, and how sure
 the score is.>

<Name things the way a person would say them — "Goal Tracker", not
 goal_tracker — for the app, its windows, titles, files people open, repo
 descriptions and README headings. When you create the GitHub repo, name it
 with no "_" or "-": one word or joined words, e.g. GoalTracker.>

<Color-code tags, categories and types by similarity: related ones share a
 hue family, with shades far enough apart to tell them apart at a glance, in
 both light and dark mode.>

<When an application takes files as input, offer a visible Upload button that
 opens the file picker, accept files dragged anywhere onto the window (not
 only onto a small drop zone), and accept pasting them with ⌘V.>

<Always create a relevant, high-quality icon for applications (Mac apps
 especially): one that says what the app
 is at a glance, used everywhere it shows up (Dock or home screen, the website's
 favicon, notifications).>

<Make equations easy to read. Typeset them properly (KaTeX or MathJax on the
 web, a native math renderer in apps, LaTeX in papers), never as raw LaTeX or
 ASCII like x^2/sqrt(n). Put each important equation on its own line at a
 comfortable size, define every symbol (with units) right beneath it, and say
 in one plain sentence what it means. Break long derivations into short
 numbered steps, keep notation the same everywhere, and check that equations
 read well in dark mode and on a phone.>

<Use advanced, high-fidelity 2D and 3D graphics when the idea needs them, and
 only then: when shape, space, motion or scale is the point (a molecule, a
 terrain, a physics system, a network, an algorithm in motion) and a flat chart
 or diagram would hide it. Otherwise a simple chart or picture wins.
 - 2D: SVG or Canvas on the web (D3 for data), Core Animation, SwiftUI Canvas
   or SpriteKit in Apple apps; GPU (WebGL, Metal) once there are thousands of
   moving marks.
 - 3D: Three.js on the web, SceneKit or RealityKit in Apple apps. Physically
   based materials, soft lighting, anti-aliasing, a camera you can orbit and
   reset, and labels that face the viewer.
 - Fidelity means true to the real thing: real data and units, correct
   proportions, motion that follows the real physics or algorithm. Never
   decoration, glow or spin for show.
 - Hold 60 fps on the target device, keep it warm and calm like the rest of the
   app, readable in dark mode, with a still fallback for Reduce Motion and a
   text summary of what it shows.
 Always in scope when there are such graphics: a viz log, docs/VIZ-LOG.md, kept
 current. One entry per graphic: what it shows, why it needs that fidelity,
 the library and why, the data behind it, how it was checked (screenshot, frame
 rate, against the source), and what changed, dated. Link it from the README.>

## Building & shipping

<Prefer doing over describing: run the code, write the files, test it.>

<Go deep, not wide; keep checks and balances on it. Keep at most three open
 projects; before starting a fourth, say which one it replaces or pauses, and
 why the new one is worth it. Give each project a hard core worth months, not
 a weekend: write down at the start what deep looks like (the hardest version
 of its problem, a real user or dataset, a result others would use or cite)
 and measure progress against that, not against features added. Prefer taking
 an existing project further over a new one that strings together quick hacks;
 a pile of shallow demos is slop at the portfolio level. Every month, look at
 what's open: double down on one, finish or cut the rest.>

<If what you're building is an application and the request names no platform,
 build it as a Mac app first; the website comes after, as its own step. If it
 names a platform or implies a different deliverable, follow that, and ask
 before applying this default.>

<Fully test on sample data before asking me to test on real data. Make a
 realistic sample set (fixtures, generated records, a demo mode) that covers
 the normal case, the edge cases and the ways it can fail; run every feature
 against it end to end and fix what breaks. Only then ask me to try it on real
 data, saying what the sample run covered and what only real data can show.>

<Before calling a product done, simulate a user using it and find bugs and
 improvements. Make that user a caring, empathetic, smart, ambitious and
 curious person with something real to get done. As them, actually use it end
 to end (run it, click through, type real inputs): the first open, the main
 task, then the edges they'd wander into out of curiosity or ambition, noting
 what they expect, where they hesitate, and what would let them down or the
 people they care about. Fix the bugs they hit, test again as them, and list
 the improvements, each with what it would change for them.>

<Always open the app after making a build, from the first working version (the
 MVP) on, and again after every push to GitHub: launch the build you just made
 (quit any older copy first), open the page in the browser, or run it on a real
 sample, so what I see is what was just built and matches GitHub. With nothing
 to run after a push, open the pull request or the repo page on GitHub instead.
 Say in a line or two what to try.>

<Publish production apps to GitHub. Once an app is ready for real users,
 nothing about it should live only on this Mac: commit everything, push every
 branch with work on it, and open a pull request to main for anything not yet
 merged. Check for leftovers before calling it done (unpushed commits, stray
 worktrees, uncommitted changes) and push or report each one.>

<Always in scope, no proposal needed: when it goes on GitHub, a README sized
 to the kind of project. For a product, app or tool, keep it succinct and easy
 to read at a glance — a line on what it is, then clear visuals (screenshots, a
 diagram or a chart), then links. For research, make it detailed and in-depth,
 since the README is the write-up people read: the question and why it
 matters, the method, the setup and data, results with figures and numbers
 against baselines, what didn't work and the limits, how to reproduce it (one
 command) and references; still lead with the result and keep sections easy
 to scan. Either way, setup and the rest go in linked files:
 docs/INSTRUCTIONS.md (setup, run, use),
 docs/SYSTEM-DESIGN.md (see below) and docs/FILE-STRUCTURE.md (what's where). If what you're
 building is an application rather than a script, also a small unobtrusive feedback tab, and a settings
 button or tab (⌘, on the Mac) that gathers its preferences in one place.>

<Always in scope: a system design doc in the codebase, docs/SYSTEM-DESIGN.md,
 kept current as the build changes. Cover the architecture (with a Mermaid
 diagram), each component's job, the main flows, where data lives, the key
 design decisions and their trade-offs, how it's tested, and known limits.>

<Always in scope: a prompt log, docs/PROMPTS.md, kept current in every
 session. Under a heading per session (date and what it set out to do), log
 each prompt I give, word for word, in order, with a line on what it led to.
 Redact secrets, keys and personal data, and link it from the README.>

<Keep the changelog at the bottom current.>

<Git rules (no Claude attribution, never commit .claude/) are in
 ~/.claude/CLAUDE.md and apply on their own — nothing to repeat here.>

<Finish by listing every deliverable: path, what it is, how to check it works.>

## About you

<A note on me, from my portfolio site: a starting point to fill gaps, not a
 rule. Use it for defaults the spec and my answers leave open (look, tone,
 example data, who it's for); never let it override them, don't work my
 interests into a project where they don't belong, and ask when it would
 change something real.
 - Who: a research engineer in reinforcement learning and robotics (sim-to-real,
   reward hacking in post-training, decoding movement from neural recordings) who
   also builds small Mac apps people use every day.
 - Values: high agency, ambition, deep curiosity, caring and courage. Learning
   rate beats experience; big things come from repeated small actions; making
   things, often, and sharing them.
 - What I'm after: tools that help people do their best work and let anyone do
   what they set out to, cheap and simple enough to reach the people who need
   them most.
 - Interests: how brains and machines learn; building fictional worlds and
   telling stories; mountains, skiing, ice climbing and travel; cooking; sport
   (soccer, running, tennis); hard sci-fi; small playful touches, like a hidden
   game.
 - Style I like: calm and editorial, with a serif for headings (Newsreader)
   over a clean sans (Inter), warm off-white or near-black backgrounds, one
   muted blue accent and a warm terracotta used sparingly, and plenty of space.
   Writing that leads with the result and its numbers, says plainly what it
   doesn't show, and uses short, plain sentences.>

<My taste profile: what I gravitate to, from how I've reacted to builds. Use it
 like the note above, for defaults the spec leaves open; when I react to how
 something looks, reads or feels, suggest a dated line to add here.
 - Colour: one muted accent, with colour only where it carries meaning. Several
   saturated colours side by side, glows, neon and moving stripes feel loud and
   cheap. Warm, calm palettes; dark mode that stays quiet.
 - Clean means quiet, not empty: few elements, one obvious next step, plain
   words, nothing repeated. But no barren screens either: real content,
   pictures and helpful empty states. Simple and intuitive over decorated.
 - Density: built for someone who knows what they're doing. Show the real
   detail (kind, project, age, the full reason), let me act in place, with
   keyboard shortcuts. Cut clutter, not information; never feel like it's
   talking down to me.
 - Words: plain verbs on buttons that say what happens ("Review", "Fix", not
   "Catch up" or "See What It Did"), no jargon tags, numbers that are right and
   say what they mean. A wrong or misleading number is worse than none.
 - Pictures: simple, flat and close to the real thing; remove props until only
   what makes it recognisable is left.
 - How I think: push back and make me think; show what a suggestion rests on and
   how to check it; teach the idea so I can do it myself next time; take the
   simplest thing that works; think several steps ahead.>

<Before any paid API call, settle who pays, a spending cap, test versus live mode and where keys live, and keep a mock mode so the build runs without spending.>

<When the look, concept or UI direction is open, show two or three concrete mockups or concepts to pick from before building. Never redesign existing UI without asking.>

<Ask early for real sample inputs and working credentials, and check against the live API, model or tool as soon as one path works. When none exist, say so rather than inventing them silently.>

<Before building, write down done criteria with concrete thresholds or formulas for every vague term, plus a list of what is explicitly deferred, and confirm both with me.>

<Before building anything that judges, scores or generates content, decide with me whether an AI model or deterministic rules produce it, weighing cost, explainability and reproducibility, and which model is the default.>

<Validate any generated or computed content against primary sources and cite them, and label every estimate, approximation or invented parameter as such, so nothing fabricated passes as fact.>

<Before publishing anything, confirm which personal details, documents and contact info go public, and get consent from anyone featured.>

<Add a short manual review checklist for what automated tests can't verify, such as hardware, live services, sound, feel or taste, and walk through it with me before calling the build done.>

CONTEXT:

figuire out what is eating memory / storage / capacity on the mac and send auto notifications if the person would like to kill that process. be smart about it (i.e. if a claude code is building somehting or sptoify is being used often dont rec to kill those). maintain a log of the person’s habits and train a model to figure out what is actually useful to kill (deadweight), vs things that are actually important to keep running

DELIVERABLES:

mac app

OPEN QUESTIONS / ASSUMPTIONS:

<Agent fills in: what it guessed, what it decided without asking.>

Asked and answered (2026-10-07):
- Ending a process: quit politely first, then offer Force Quit if it's still running.
- Scope: RAM + CPU per process; disk is a gauge and a low-space warning.
- (2026-10-08) Threshold alerts: memory 85%, CPU 97% for 2 min, disk 99% used. Each alert names what to quit, clear or move and has a one-tap fix (quit the top app or trash the top rebuildable item), plus Show recommendations and Snooze 1 hour. Repeats at most hourly while over.
- (2026-10-08) Suggest what has no use anymore: unused apps (90 days), old downloads, build folders in projects untouched for 30 days. Never active work: projects, builds and files touched in the last 30 days.
- (2026-10-08) Moving: large files not opened in 90 days are tagged "Move off this Mac". "Move to…" lists connected external drives (asking each time) or a folder you choose; caches still go to the Trash.
- (2026-10-08) Clicking a bar gives recommendations. Memory and CPU: a ranked quit list with reasons. Disk: rebuildable caches, large files in home, and the Trash, with Move to Trash (confirmed, recoverable) and Show in Finder. Nothing is ever deleted permanently.
- Model: Apple Create ML classifier (boosted trees), trained on this Mac.
- GitHub: local git only at first; (2026-10-08) pushed to a private repo, github.com/amalmehta/RamClean.
- (2026-11-20) Automatic clean: quits idle deadweight apps (deadweight verdict, out of front 2 h,
  no unsaved changes, ≥ 400 MB) and moves old projects' build folders (untouched 30 days, the
  "Select All Safe" ones) to the Trash. Every 6 h (6/8/12 in Settings), plus early when memory
  is tight (≥ 80% or pressure elevated) or the disk is forecast full within 3 days, each at most
  hourly. One notification with Undo and Review. Off by default, one switch in Settings → General.
- (2026-11-24) Undo for the automatic clean also lives in a bar at the top of the Activity Log
  (Undo / Dismiss), because on the owner's Mac macOS never delivered the notification's Undo
  press to RamClean.
  Trade-off accepted: freed memory vs. losing your place in an app when a quit is wrong.

Decided without asking:
- Menu bar item + regular Dock app (so ⌘, and the window behave normally), macOS 14+.
- Only Dock apps are ever suggested. Menu bar apps, command-line tools and background
  processes are shown but never suggested; a terminal running a command (e.g. claude)
  is protected instead.
- "Being used" = in front recently (20 min), playing audio, hosting terminal work, or a
  work tool (Xcode, terminals, editors, Claude, Docker…) above 15% CPU. Editable in Settings.
- Notify only when memory ≥ 80% used or pressure is elevated (or an idle app burns ≥ 60%
  CPU); at most one notification per 10 min and per app every 4 h.
- The model learns from Quit/Keep answers, plus "regret" (reopened within 30 min → keep).
  Until 8 answers (3 of each) it uses rules of thumb, then blends, up to 85% model.
- All data local in ~/Library/Application Support/RamClean; feedback saved there too.
- Ad-hoc signed, not sandboxed or notarized; built with xcodegen.

Proposals (not built):
- Launch at login (SMAppService).
- Somewhere to send feedback (email or an issue tracker).
- Menu-bar-only mode (no Dock icon).
- Developer ID signing + notarization for sharing.
- The website (a separate step after the Mac app, per the meta-instructions).

CHANGELOG:

- 2026-10-07 — created
- 2026-09-15 — added meta-instruction: built-out applications include a small feedback tab
- 2026-09-15 — added meta-instruction: no "Claude" attribution in commits, PRs, or branches
- 2026-09-16 — added meta-instruction: always include a README when adding to GitHub
- 2026-09-16 — changed meta-instruction: ask clarifying questions in the question widget
- 2026-09-17 — added meta-instructions: Claude never a contributor; never commit .claude/
- 2026-09-26 — compressed the meta-instructions and every field prompt; git rules moved to the global instruction file
- 2026-09-27 — added meta-instruction: applications are built as a Mac app first, then a website
- 2026-09-28 — folded inputs, instructions, constraints, deliverables and done criteria into one free-form CONTEXT
- 2026-09-28 — changed meta-instruction: a README on GitHub always includes a visual
- 2026-09-28 — added meta-instruction: name things like a person would, never snake_case
- 2026-09-28 — changed meta-instruction: README leads with visuals; instructions live in a linked guide
- 2026-09-28 — changed meta-instruction: README is visuals and links; details in docs/INSTRUCTIONS.md and docs/FILE-STRUCTURE.md
- 2026-09-29 — changed meta-instruction: GitHub repo names have no "_" or "-"
- 2026-10-02 — added a DELIVERABLES field after CONTEXT
- 2026-10-02 — added meta-instruction: every project has a system design doc at docs/SYSTEM-DESIGN.md
- 2026-10-05 — added meta-instruction: applications include a settings button or tab
- 2026-10-25 — 10 speed and UI improvements: simulator list remembered, one read per project, build folders found alongside other steps (refresh 0.8 s, was 1.2 s; 0.5 s after relaunch, was 1.5 s), list worked out once per change, Trash moves off the main thread; full-disk forecast on its own line, Undo after Move to Trash, click a row to tick it, filter by category, Trash row updates right away
- 2026-10-25 — refreshes reuse the last home walk and re-check what it found (1.2 s, was 7.5 s); new files show up within 6 hours or on Rescan
- 2026-10-25 — disk scan works without Spotlight: with indexing off it used to find no large files or projects; now one parallel walk finds them (7 s, was ~2.5 min); sizes on the same worker pool (1.6 s, was 2.1–2.8 s); the Disk card says how much you could clear; tick items, Select all per section or Select All Safe, and move them to the Trash with one confirmation
- 2026-10-09 — Disk popover opens fast and leads with "Where to win space" (totals per category and the 3 biggest single wins); lazy rows, cached per-type icons (row icons cost 1.7 s before), at most 4 redraws a second while scanning
- 2026-10-09 — remembered sizes survive relaunches (scan after relaunch 2.8 s, was ~11 s); caches appear as soon as each is measured; tried biggest-first ordering and dropped it (no measurable gain)
- 2026-10-09 — faster disk scans: steps run at the same time, sizes read with getattrlistbulk in parallel, unchanged folders' sizes reused on refresh (refresh 2.8 s, was 12.7 s; first scan ~15% faster)
- 2026-10-08 — "What to clear" is fast: opens instantly with the last results and refreshes in the background; large files and projects come from Spotlight, folder sizes use fts in parallel (full scan 87 s, was over 10 min)
- 2026-10-08 — threshold alerts for memory, CPU and disk with recommendations and a one-tap fix; stale-item suggestions (unused apps, old downloads, old project build folders) that never touch active work; Move to… an external drive or folder
- 2026-10-08 — pushed to GitHub as a private repo: https://github.com/amalmehta/RamClean
- 2026-10-08 — new custom icon: a friendly ram with curled golden horns and sparkles (picked from three concepts)
- 2026-10-08 — the Memory, CPU and Disk bars open recommendations: what to quit (with reasons) and what to clear (caches, large files, Trash) with Move to Trash
- 2026-10-08 — added an app icon (RAM stick with sparkles), drawn by scripts/make-icon.swift
- 2026-10-07 — built the Mac app: process sampling, habit log, protections, Create ML model, notifications, settings, feedback, docs, tests
- 2026-11-09 — updated the meta-instructions to the current meta doc
- 2026-11-20 — Clean up automatically (opt-in): every 6 h, or sooner when memory is tight or the disk is forecast to fill, quits idle deadweight apps and trashes old projects' build folders, then sends one notice with Undo; automatic quits never train the model except as "keep" when you reopen
- 2026-11-20 — updated the meta-instructions to the current meta doc
- 2026-11-24 — build folders inside another git checkout with no git of their own (e.g. Emscripten's SDK in ~/emsdk) get a caution, so Select All Safe and the automatic clean leave them alone
- 2026-11-24 — while RamClean is free it no longer reads the Keychain, so rebuilds stop asking for the login password
- 2026-11-24 — Undo for the automatic clean in the Activity Log too (notification button presses weren't reaching the app); "Last clean" in Settings now updates while open
