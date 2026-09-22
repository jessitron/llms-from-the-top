# 5 Skills

We want to tell our agent how to do stuff.

One way is in AGENTS.md, that standard file at the root of the project that agents will pick up and read as part of the system prompt.

## Do this

1. When your agent starts up, look for AGENTS.md. If it exists in the current directory, read it into the system prompt.

Example: vort_6a.rb

## Try this

In test-changelog/workspace-5a, there's a very very tiny project with an AGENTS.md

Try getting your agent to change the program. `Default the greeting to $USER` or `Take a required argument --name` or `Generate a random greeting instead. Make a commit` Does it add to the changelog correctly??

The AGENTS.md here is much longer than the rest of the project put together. Whatever is in there, it gets sent on every single request forever. If the agent makes six loops, you're paying input tokens x6 for it.

A strategy with agents is "progressive disclosure" -- make sure they always know how to find something, and then let them read in details when they need them.

## Try this

Try the same test, but in workspace-5c, where the AGENTS.md is short. It references two files in skills/ instead.

It should get the changelog right, but use fewer tokens. It doesn't read the changelog instructions until near the end, so they get sent 2-3x instead of every loop in the whole conversation. It doesn't read the commit instructions at all.

## Do this

People like this idea so much that they make it generic. In workspace_2b, the same arrangement is done with skills: the markdown files in `skills/` have a `Trigger:` phrase.

2. Make a tool "load_skill" that reads in a file from `skills/`. In the tool description, build a catalog of the skills that are there by reading the files in `skills/`; the description should include each one's name and trigger phrase.

Example: vort_5b.rb

## Try this

Run your agent in workspace-5b, and see if it gets the changelog right.

There's a script eval_5.rb in test-changelog/ that runs all three of these.

## Notice that

Skills are just a weird tool that reads a file! They're useful for progressive disclosure, which you can do without a specific tool. Skills don't have to be located in the project, though; and that means they can be shared.

A skill is just a prompt! (or part of one)
