FROM ruby:3.4-slim

# the 6-subagents examples run git (the commit subagent)
# build-essential: vort_6c's OTel gems pull in bigdecimal, a native extension
RUN apt-get update && apt-get install -y --no-install-recommends git build-essential && rm -rf /var/lib/apt/lists/*
RUN git config --global user.name "workshop" && git config --global user.email "workshop@example.com"

# pre-install vort_6c's bundler/inline gems, so it doesn't compile them on every start
RUN gem install --no-document opentelemetry-sdk opentelemetry-exporter-otlp

WORKDIR /workshop

COPY examples/ examples/

CMD ["bash"]
