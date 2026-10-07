defmodule Ear.Web.PageController do
  use Phoenix.Controller, formats: [:html, :json]

  def index(conn, _params) do
    page =
      :ear
      |> Application.app_dir("priv/web/index.html")
      |> File.read!()
      |> String.replace("__CSRF_TOKEN__", Plug.CSRFProtection.get_csrf_token())

    html(conn, page)
  end

  def state(conn, _params), do: json(conn, Ear.Web.Session.state())

  def prompt(conn, %{"prompt" => prompt}) when is_binary(prompt),
    do: respond(conn, Ear.Web.Session.prompt(prompt))

  def prompt(conn, _params), do: respond(conn, {:error, :invalid_prompt})
  def cancel(conn, _params), do: respond(conn, Ear.Web.Session.cancel())
  def clear(conn, _params), do: respond(conn, Ear.Web.Session.clear())

  defp respond(conn, :ok), do: json(conn, %{ok: true})

  defp respond(conn, {:error, reason}) do
    status = if reason == :run_in_progress, do: 409, else: 422
    conn |> put_status(status) |> json(%{error: inspect(reason)})
  end
end
