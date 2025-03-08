FROM node:16-alpine
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY package*.json ./
RUN chown -R appuser:appgroup /app
USER appuser
RUN npm install
COPY --chown=appuser:appgroup . .
RUN npm run build

# Install serve in the user's directory instead of globally
RUN npm install serve

EXPOSE 3000
# Run serve using the local installation
CMD ["./node_modules/.bin/serve", "-s", "build", "-l", "3000"]