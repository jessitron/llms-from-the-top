FROM ruby:3.4-slim

# the 6-subagents examples run git (the commit subagent)
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*
RUN git config --global user.name "workshop" && git config --global user.email "workshop@example.com"

WORKDIR /workshop

COPY examples/ examples/

CMD ["bash"]
