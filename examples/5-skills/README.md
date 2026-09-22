# 5 Skills

We want to tell our agent how to do stuff.

One way is in AGENTS.md, that standard file at the root of the project that agents will pick up and read as part of the system prompt.

## Do this

When your agent starts up, look for AGENTS.md. If it exists in the current directory, read it into the system prompt.

Example: vort_6a.rb

## Try this

In test-changelog/workspace-5a, there's a very very tiny project with an AGENTS.md

Try getting your agent to change the program. `Default the greeting to $USER` or `Take a required argument --name` or `Generate a random greeting instead. Make a commit` Does it add to the changelog correctly??

The AGENTS.md here is much longer than the rest of the project put together. Whatever is in there, it gets sent on every single request forever. If the agent makes six loops, you're paying input tokens x6 for it.

A strategy with agents is "progressive disclosure" -- make sure they always know how to find something, and then 

## Do this

