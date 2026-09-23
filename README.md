# LLMs From the Top

A [workshop for Explore DDD](https://exploreddd.com/schedule/?session=1188182).

During the workshop, find API details here: [https://llms-from-the-top.jessitron.com]()
(that link should not work afterward)

## Workshop Abstract

A good part of being alive and in software development right now: we're watching the journey from LLM to coding agent to agent swarm or whatever is next.

A tough part: it's a lot to follow!

If you're feeling like you missed something, if this all seems way too complicated, this session will catch you up. We'll

- start with an LLM (from the outside)
- build chat, and see what's weird about that
- add tools, poof we have an agent
- add skills, subagents, and more techniques for managing context
- see the WHY and the behind-the-scenes for each layer.

There will be live coding. At each step you'll get an important tip for working with these tools, and you'll know why it works.

After this session, you'll understand the WHY and HOW of magical coding agent parts. This sets you up for success in using them.

## Workshop format

Write your own code to do this as we go along! Or run mine, as provided for each step. The LLM you'll use is behind an API that I own, and it sends telemetry to Honeycomb so we can all look at it during the workshop.

**Anything text you send may be used as an example for the group to see.**

## Outline

This is the planned material, but if we get off on tangents, great! The point is to play with this and learn stuff together. Right now everyone has different bits of knowledge about how to work with these tools. I'm gonna learn some stuff from you in here, you'll pick something or other up from me, and we'll all learn from each other.

1. What is an LLM? try out a completion machine with an API call.
2. Make a loop to create a chatbot.
3. Add a system prompt to give it character.
4. Implement tools to make it an agent.
5. Give skills to make it smarter.
6. Maybe we'll talk about subagents.

## Running the examples

You can write your own code, and/or run the examples in this repo.

To run the examples, you need Ruby 3.4.6 or better. If you don't have Ruby installed, this will open a prompt in a suitable container:

`./run-in-docker`

## Telemetry

THe API provided for this workshop (llms-from-the-top.jessitron.com) sends telemetry to Honeycomb. We are gonna look at that during the workshop. You can look at some of it, too, as it sends to a Honeycomb sandbox environment. Only part of Honeycomb is available there, but check out

[the query editor](https://play.honeycomb.io/sandbox/environments/workshop)

[What people are asking and the responses they get](https://play.honeycomb.io/sandbox/environments/workshop/datasets/llms-from-the-top-edge-proxy/result/diw7mXMuTzk)

[scores and token counts by conversation](https://play.honeycomb.io/sandbox/environments/workshop/result/sJ7aeLhMx1x)

## Evals

How do we know it works? Today, for play, it's enough to try it out and see. There are also some programs in this repo that exercise its agent implementations. They're only deterministic, not incorporating LLM-as-judge, but at coding tasks you can measure success. The evals make it faster to compare implementations as I tweak my bots.

## This Repository

This repository holds:

[ ] Example code (in examples/)
[ ] Test scenarios (down in the examples)
[ ] Some eval scripts that work on the examples (down in the examples and the test scripts)
[ ] The backend of the LLM API you'll use during the workshop (edge-proxy and llm-api)
