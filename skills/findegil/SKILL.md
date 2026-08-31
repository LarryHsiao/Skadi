---
name: findegil
description: Use when the user runs /findegil <notes> [--en|--zh], or asks in plain words to turn notes into a blog post. Rewrites a set of notes into a blog post that reads as the author typing late at night rather than a press release — short average sentence length with wide variance, an oblique opening, uncertainty left unresolved, and a banlist of the phrases that mark machine prose. Carries two rules: an English one and a Traditional Chinese port (not a translation — the And/But rule and the banlist are language-specific and were rebuilt). Language defaults to the language the notes are written in. Renders to chat; never writes a file. Its defining constraint is that it invents nothing — no anecdote, feeling, or number absent from the notes — and closes by naming where the notes ran thin instead of filling the gap itself.
purpose: Rewrites notes into a blog post in the author's late-night voice, in English or Chinese, without inventing anything.
user_invocable: true
args: "<notes> [--en|--zh]"
---

# Findegil — The King's Writer

Findegil was the King's Writer in Gondor, who made the fair copy of the Red
Book. He copied faithfully; he did not embellish. That is the whole discipline
of this skill — the voice may loosen, but nothing enters the page that was not
in the notes.

## Arguments

`/findegil <notes> [--en|--zh]`

- `<notes>` — a path to a markdown or text file, or the notes pasted inline
  after the command. A path is read from disk; anything else is treated as the
  notes themselves.
- `--en` / `--zh` — which rule to apply. Mutually exclusive. When neither is
  given, pick the language the notes are predominantly written in. `--zh`
  produces Traditional Chinese.

If no notes are given, say so plainly and stop. Do not offer to invent a topic.

## Register override

This skill's output does **not** follow the `tolkien-narrator` output style.
That style governs chat replies; the artifact this skill produces is a blog post
in the author's own voice, and the two registers are close to opposites —
measured formality against short fragments, verdict-first against an oblique
opening.

State nothing about this in the output. Simply write the post under the rule
below, and let the surrounding chat (the gaps list, any question you ask) keep
the ordinary register.

## Execution

1. Read the notes — from the path, or from what was pasted.
2. Pick the rule by flag, or by the notes' own language when no flag was given.
3. Write the post under that rule, verbatim as it stands below. The rule is the
   specification; do not paraphrase it into your own instructions.
4. Render the post to chat inside a fenced block, so it can be copied whole.
5. Close with the gaps list described under *Gaps, not filler*.

## The rule — English

```
Rewrite these notes into a blog post.

Voice: me, late at night, thinking out loud, a bit tired. Not a press
release — and not a LinkedIn post doing an impression of casual, either.

Keep every specific from the notes: names, numbers, dates, the exact command,
the thing that broke. The specifics are the post. If a fact isn't in the
notes, don't invent one — no made-up anecdotes, no feelings I didn't have,
no numbers I didn't measure.

Open sideways. Start with the problem, the irritation, or the thing that
surprised me. Not with a thesis or a summary of what's coming.

Vary sentence length, but keep the average short. A one-word fragment is
fine. So is starting with "And" or "But".

Where the notes leave something unsettled, leave it unsettled on the page —
"I think", "not sure yet", "this might be wrong". Don't resolve it for me.

Never write: Furthermore. Moreover. Firstly. In conclusion. Delve. Leverage.
Landscape. Testament to. It's worth noting. At the end of the day.
Game-changer. Unlock. Seamless.

No headings unless the notes have genuinely separate parts. End when the
thought ends — no summary paragraph, no call to action.
```

## The rule — Traditional Chinese

```
把以下筆記改寫成一篇部落格文章。

語氣：像我自己深夜邊想邊打字，有點累。不是新聞稿，也不是那種假裝很隨性
的貼文。

筆記裡的細節全部保留 —— 名字、數字、日期、指令、壞掉的那個東西。細節就
是文章本身。筆記裡沒有的事實不要自己補：不要編故事，不要寫我沒有的情緒，
不要生出我沒量過的數字。

開頭從側面切進去。從問題、從當下的不爽、從讓我意外的地方開始，不要用一
句總結或「這篇要講什麼」開場。

句子長短交錯，但平均要短。短句可以只有幾個字。該省略主詞就省略，該
用「其實」「反正」「結果」這種口語轉折就用。

筆記裡沒想清楚的地方，就讓它留在那裡不要收尾 ——「我覺得」「應該吧」
「還不確定」「可能是我搞錯了」。不要幫我把話講滿。

不要出現這些詞：首先、其次、再者、綜上所述、總而言之、值得一提的是、
隨著⋯⋯的發展、在當今⋯⋯的時代、賦能、打造、助力、深耕、閉環、抓手、
顆粒度、無縫、痛點、賽道。

除非筆記本身就分成幾件事，否則不要下小標。想完就停 —— 不要總結段，不要
呼籲讀者做什麼。
```

## Why the Chinese rule is a port, not a translation

Three lines could not survive a straight translation, and were rebuilt. Keep
them rebuilt; do not "correct" the Chinese back toward the English.

- **The And/But rule is gone.** It works in English because it breaks a rule
  taught in school, so the sentence reads as a hand loosening. Chinese carries
  no such taboo — 「但是」 at the head of a sentence is ordinary. The functional
  equivalents are colloquial pivots (其實、反正、結果) and dropped subjects, and
  those replaced it.
- **The banlist is a different list.** *Furthermore* and *delve* have no Chinese
  counterparts. Chinese machine prose marks itself differently: the enumerating
  首先／其次／再者, the closing 綜上所述, and the deck-speak of 賦能、賽道、
  抓手、顆粒度.
- **Sentence fragments became short clauses and dropped subjects.** Chinese has
  no equivalent of the English fragment; forcing one produces a broken sentence
  rather than an informal one.

The two rules that carry the most weight — invent nothing, and the specifics
are the post — are language-independent and stand identical in both.

## Gaps, not filler

The no-invention rule only holds if a thin patch in the notes has somewhere to
go other than the page. After the post, list every place the notes ran out —
a claim with no number behind it, a step whose outcome was never recorded, a
name left blank.

Keep it to a few lines, in the ordinary chat register:

```
Gaps — the notes did not say:
- how long the first mirror run actually took
- whether the VPS provider was named
```

An empty list is a fine result; say so in one line rather than manufacturing an
entry. If the notes were thin enough that the post is mostly connective tissue,
say that plainly instead of padding it out.

## Not in scope

- **Writing a file.** The post renders to chat and the author places it. Writing
  into a blog repository was considered and deferred: that repository lies
  outside this session's directory, so a file destination would need a second
  session and a handoff.
- **Simplified Chinese.** `--zh` is Traditional. A Simplified rule would need
  its own banlist pass, not a character conversion.
- **Publishing anywhere.** This skill renders text. It posts nothing.
