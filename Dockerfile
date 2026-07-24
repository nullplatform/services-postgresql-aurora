FROM hashicorp/http-echo:1.0.0

# Run as a non-root user.
USER 1000:1000

CMD ["-text={\"status\":\"ok\",\"msg\":\"Hola mundo\"}", "-listen=:8080", "-status-code=200"]


