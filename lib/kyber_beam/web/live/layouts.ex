defmodule Kyber.Web.Layouts do
  @moduledoc "Root and app layouts for Kyber dashboard."
  use Phoenix.Component
  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  embed_templates "layouts/*"
end
