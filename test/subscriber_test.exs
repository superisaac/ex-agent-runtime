defmodule Ear.SubscriberTest do
  use ExUnit.Case, async: false

  test "invalid subscribers do not crash a run" do
    assert {:ok, %{text: "ok"}} =
             Ear.run("hello",
               adapter: Ear.Model.Scripted.new([%{text: "ok"}]),
               subscriber: :invalid_subscriber
             )
  end

  test "subscribe rejects invalid subscribers" do
    assert {:error, :invalid_subscriber} = Ear.subscribe("missing", :not_a_pid)
  end

  test "unsubscribe rejects invalid subscribers" do
    assert {:error, :invalid_subscriber} = Ear.unsubscribe("missing", :not_a_pid)
  end

  test "a subscriber that exits does not break the run" do
    subscriber =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    send(subscriber, :stop)

    assert {:ok, %{text: "ok"}} =
             Ear.run("hello",
               adapter: Ear.Model.Scripted.new([%{text: "ok"}]),
               subscriber: subscriber
             )
  end
end
