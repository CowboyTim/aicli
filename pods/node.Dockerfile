# The node pod: nodejs and npm (node, npm, npx), for nodejs projects. It runs only
# those programs (broker.json), so it does not need the basic tools beyond its image.
FROM node:22-bookworm-slim
WORKDIR /work
