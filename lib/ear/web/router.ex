defmodule Ear.Web.Router do
  use Phoenix.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", Ear.Web do
    pipe_through(:browser)
    get("/", PageController, :index)
    get("/api/state", PageController, :state)
    post("/api/prompt", PageController, :prompt)
    post("/api/cancel", PageController, :cancel)
    post("/api/clear", PageController, :clear)
  end
end
