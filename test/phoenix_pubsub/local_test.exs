defmodule Phoenix.PubSub.LocalTest do
  use ExUnit.Case, async: true
  use Phoenix.PubSub.Interceptor
  alias Phoenix.PubSub.Local

  defp list(config) do
    Enum.reduce(0..(config.pool_size - 1), [], fn shard, acc ->
      acc ++ Local.list(config.pubsub, shard)
    end)
  end

  defp subscribers(config, topic) do
    Enum.reduce(0..(config.pool_size - 1), [], fn shard, acc ->
      acc ++ Local.subscribers(config.pubsub, topic, shard)
    end)
  end

  def handle_broadcast("intercept", :passthrough = msg, _server) do
    {:ok, msg}
  end
  def handle_broadcast("intercept", :ignored, _server) do
    :ignore
  end
  def handle_broadcast("intercept", :customized, _server) do
    {:ok, :did_customize}
  end

  setup config do
    size = config[:pool_size] || 1
    {:ok, _} = Phoenix.PubSub.LocalSupervisor.start_link(config.test, size, [])
    {:ok, %{pubsub: config.test,
            pool_size: size}}
  end

  for size <- [1, 8] do
    @tag pool_size: size
    test "pool #{size}: subscribe/2 joins a pid to a topic and broadcast/2 sends messages", config do
      # subscribe
      pid = spawn fn -> :timer.sleep(:infinity) end
      assert subscribers(config, "foo") == []
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, self, "foo")
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, pid, "foo")
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, self, "bar")

      # broadcast
      assert :ok = Local.broadcast(nil, nil, config.pubsub, config.pool_size, :none, "foo", :hellofoo)
      assert_received :hellofoo
      assert Process.info(pid)[:messages] == [:hellofoo]

      assert :ok = Local.broadcast(nil, nil, config.pubsub, config.pool_size, :none, "bar", :hellobar)
      assert_received :hellobar
      assert Process.info(pid)[:messages] == [:hellofoo]

      assert :ok = Local.broadcast(nil, nil, config.pubsub, config.pool_size, :none, "unknown", :hellobar)
      assert Process.info(self)[:messages] == []
    end

    @tag pool_size: size
    test "pool #{size}: unsubscribe/2 leaves group", config do
      pid = spawn fn -> :timer.sleep(:infinity) end
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, self, "topic1")
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, pid, "topic1")

      assert Enum.sort(subscribers(config, "topic1")) == Enum.sort([self, pid])
      assert :ok = Local.unsubscribe(config.pubsub, config.pool_size, self, "topic1")
      assert subscribers(config, "topic1") == [pid]
    end

    @tag pool_size: size
    test "pool #{size}: unsubscribe/2 gargabes collect topic when there are no more subscribers", config do
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, self, "topic1")

      assert list(config) == ["topic1"]
      assert Local.unsubscribe(config.pubsub, config.pool_size, self, "topic1")

      assert Enum.count(list(config)) == 0
      assert Enum.count(subscribers(config, "topic1")) == 0
    end

    @tag pool_size: size
    test "pool #{size}: unsubscribe/2 when topic does not exist", config do
      assert :ok = Local.unsubscribe(config.pubsub, config.pool_size, self, "notexists")
      assert Enum.count(subscribers(config, "notexists")) == 0
    end

    @tag pool_size: size
    test "pool #{size}: pid is removed when DOWN", config do
      {pid, ref} = spawn_monitor fn -> :timer.sleep(:infinity) end
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, self, "topic5")
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, pid, "topic5")
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, pid, "topic6")

      Process.exit(pid,  :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      # Ensure DOWN is processed to avoid races
      Local.subscribe(config.pubsub, config.pool_size, pid, "unknown")
      Local.unsubscribe(config.pubsub, config.pool_size, pid, "unknown")

      assert Local.subscription(config.pubsub, config.pool_size, pid) == {nil, []}
      assert subscribers(config, "topic5") == [self]
      assert subscribers(config, "topic6") == []

      # Assert topic was also garbage collected
      assert list(config) == ["topic5"]
    end

    @tag pool_size: size
    test "pool #{size}: subscriber is demonitored when it leaves the last topic", config do
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, self, "topic7")
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, self, "topic8")

      {ref, topics} = Local.subscription(config.pubsub, config.pool_size, self)
      assert is_reference(ref)
      assert Enum.sort(topics) == ["topic7", "topic8"]

      assert :ok = Local.unsubscribe(config.pubsub, config.pool_size, self, "topic7")
      {ref, topics} = Local.subscription(config.pubsub, config.pool_size, self)
      assert is_reference(ref)
      assert Enum.sort(topics) == ["topic8"]

      :ok = Local.unsubscribe(config.pubsub, config.pool_size, self, "topic8")
      assert Local.subscription(config.pubsub, config.pool_size, self) == {nil, []}
    end

    test "pool #{size}: broadcast with interceptor", config do
      assert :ok = Local.subscribe(config.pubsub, config.pool_size, self, "intercept")
      assert :ok = Local.broadcast(__MODULE__, nil, config.pubsub, config.pool_size, :none, "intercept", :passthrough)
      assert_receive :passthrough

      assert :ok = Local.broadcast(__MODULE__, nil, config.pubsub, config.pool_size, :none, "intercept", :ignored)
      refute_receive _

      assert :ok = Local.broadcast(__MODULE__, nil, config.pubsub, config.pool_size, :none, "intercept", :customized)
      refute_receive :customized
      assert_receive :did_customize

      assert :ok = Local.broadcast(__MODULE__, nil, config.pubsub, config.pool_size, :none, "intercept", :default)
      assert_receive :default
    end
  end
end
