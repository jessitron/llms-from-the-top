FROM ruby:3.4-slim

WORKDIR /workshop

COPY examples/ examples/

CMD ["bash"]
