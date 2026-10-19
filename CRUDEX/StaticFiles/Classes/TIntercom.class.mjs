"use strict";

/** Um intercomunicador por instância do sistema. Mensagens são valores JSON. */
export default class TIntercom {
    #Socket = null;
    #URL;

    OnOpen = null;
    OnMessage = null;
    OnClose = null;
    OnError = null;

    constructor(url) {
        this.#URL = url;
    }

    async Connect() {
        if (this.IsOpen)
            return this;

        if (this.#Socket && this.#Socket.readyState !== WebSocket.CLOSED)
            throw new Error("O Intercom já está conectando ou encerrando a conexão.");

        const socket = new WebSocket(this.#URL);
        this.#Socket = socket;

        return new Promise((resolve, reject) => {
            socket.addEventListener("open", () => {
                resolve(this);
                this.OnOpen?.();
            });

            socket.addEventListener("message", event => {
                let message;

                try {
                    message = JSON.parse(event.data);
                } catch (error) {
                    this.OnError?.(error);
                    return;
                }

                this.OnMessage?.(message);
            });

            socket.addEventListener("error", () => {
                const error = new Error("Falha na conexão do Intercom.");
                reject(error);
                this.OnError?.(error);
            });

            socket.addEventListener("close", event => {
                reject(new Error("O Intercom foi encerrado antes de conectar."));
                this.OnClose?.(event);
            });
        });
    }

    Send(message) {
        if (!this.IsOpen)
            throw new Error("O Intercom não está conectado.");

        const json = JSON.stringify(message);

        if (json === undefined)
            throw new Error("A mensagem deve ser um valor JSON.");

        this.#Socket.send(json);
    }

    Close(code = 1000, reason = "") {
        this.#Socket?.close(code, reason);
    }

    get IsOpen() {
        return this.#Socket?.readyState === WebSocket.OPEN;
    }
}
