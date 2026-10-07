defmodule Ear.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :ear

  plug(Plug.Static, at: "/", from: {:ear, "priv/web"}, only: ~w(app.js app.css icons))
  plug(Plug.RequestId)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(Plug.Session, store: :cookie, key: "_ear_web", signing_salt: "ear_web_session")
  plug(Ear.Web.Router)
end

defmodule Ear.Web.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule Ear.Web.ErrorJSON do
  def render(template, _assigns),
    do: %{error: Phoenix.Controller.status_message_from_template(template)}
end
