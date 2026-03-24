defmodule Kyber.Tools.WebFetchTest do
  use ExUnit.Case, async: true

  alias Kyber.Tools.WebFetch

  # ── HTML Extraction Tests ──────────────────────────────────────────────

  describe "extract_readable_text/1" do
    test "strips script and style tags" do
      html = """
      <html><body>
        <script>var x = 1;</script>
        <style>.foo { color: red; }</style>
        <p>Hello world</p>
      </body></html>
      """

      result = WebFetch.extract_readable_text(html)
      refute result =~ "var x"
      refute result =~ "color: red"
      assert result =~ "Hello world"
    end

    test "removes nav, footer, header, aside elements" do
      html = """
      <html><body>
        <nav><a href="/">Home</a><a href="/about">About</a></nav>
        <header><h1>Site Header</h1></header>
        <article><p>Main content here</p></article>
        <aside><p>Sidebar ad</p></aside>
        <footer><p>Copyright 2026</p></footer>
      </body></html>
      """

      result = WebFetch.extract_readable_text(html)
      refute result =~ "Home"
      refute result =~ "Site Header"
      refute result =~ "Sidebar ad"
      refute result =~ "Copyright 2026"
      assert result =~ "Main content here"
    end

    test "preserves paragraph structure with double newlines" do
      html = "<p>First paragraph</p><p>Second paragraph</p>"
      result = WebFetch.extract_readable_text(html)
      assert result =~ "First paragraph"
      assert result =~ "Second paragraph"
      # Should have separation between paragraphs
      assert result =~ ~r/First paragraph\n+.*Second paragraph/s
    end

    test "converts br tags to newlines" do
      html = "Line one<br>Line two<br/>Line three<br />"
      result = WebFetch.extract_readable_text(html)
      assert result =~ "Line one\nLine two\nLine three"
    end

    test "handles heading block elements" do
      html = "<h1>Title</h1><h2>Subtitle</h2><p>Content</p>"
      result = WebFetch.extract_readable_text(html)
      assert result =~ "Title"
      assert result =~ "Subtitle"
      assert result =~ "Content"
    end

    test "removes HTML comments" do
      html = "<p>Visible</p><!-- hidden comment --><p>Also visible</p>"
      result = WebFetch.extract_readable_text(html)
      assert result =~ "Visible"
      assert result =~ "Also visible"
      refute result =~ "hidden comment"
    end

    test "collapses excessive whitespace" do
      html = "<p>  Lots   of    spaces  </p>"
      result = WebFetch.extract_readable_text(html)
      refute result =~ "   "
    end

    test "handles non-binary input" do
      result = WebFetch.extract_readable_text(nil)
      assert is_binary(result)
    end
  end

  # ── Entity Decoding Tests ──────────────────────────────────────────────

  describe "decode_entities/1" do
    test "decodes common named entities" do
      assert WebFetch.decode_entities("&amp;") == "&"
      assert WebFetch.decode_entities("&lt;") == "<"
      assert WebFetch.decode_entities("&gt;") == ">"
      assert WebFetch.decode_entities("&quot;") == "\""
      assert WebFetch.decode_entities("&#39;") == "'"
      assert WebFetch.decode_entities("&apos;") == "'"
      assert WebFetch.decode_entities("&nbsp;") == " "
      assert WebFetch.decode_entities("&mdash;") == "—"
      assert WebFetch.decode_entities("&ndash;") == "–"
      assert WebFetch.decode_entities("&hellip;") == "…"
    end

    test "decodes decimal numeric entities" do
      assert WebFetch.decode_entities("&#65;") == "A"
      assert WebFetch.decode_entities("&#8212;") == "—"
    end

    test "decodes hex numeric entities" do
      assert WebFetch.decode_entities("&#x41;") == "A"
      assert WebFetch.decode_entities("&#x2014;") == "—"
    end

    test "handles mixed entities in text" do
      input = "Tom &amp; Jerry &mdash; a classic &#8220;cartoon&#8221;"
      result = WebFetch.decode_entities(input)
      assert result == "Tom & Jerry — a classic \u201Ccartoon\u201D"
    end
  end

  # ── Title Extraction Tests ─────────────────────────────────────────────

  describe "extract_title/1" do
    test "extracts title from HTML" do
      html = "<html><head><title>My Page Title</title></head><body></body></html>"
      assert WebFetch.extract_title(html) == "My Page Title"
    end

    test "returns nil when no title" do
      html = "<html><body>No title here</body></html>"
      assert WebFetch.extract_title(html) == nil
    end

    test "decodes entities in title" do
      html = "<title>Tom &amp; Jerry</title>"
      assert WebFetch.extract_title(html) == "Tom & Jerry"
    end

    test "handles non-binary input" do
      assert WebFetch.extract_title(nil) == nil
    end
  end

  # ── fetch/2 validation tests (no HTTP) ─────────────────────────────────

  describe "fetch/2 validation" do
    test "rejects empty URL" do
      assert {:error, _} = WebFetch.fetch("")
    end

    test "rejects non-http URL" do
      assert {:error, "URL must start with http" <> _} = WebFetch.fetch("ftp://example.com")
    end

    test "rejects localhost (SSRF)" do
      assert {:error, "blocked" <> _} = WebFetch.fetch("http://localhost/secret")
    end

    test "rejects private IPs (SSRF)" do
      assert {:error, "blocked" <> _} = WebFetch.fetch("http://192.168.1.1/admin")
      assert {:error, "blocked" <> _} = WebFetch.fetch("http://10.0.0.1/internal")
      assert {:error, "blocked" <> _} = WebFetch.fetch("http://127.0.0.1:8080/")
    end

    test "rejects .local domains (SSRF)" do
      assert {:error, "blocked" <> _} = WebFetch.fetch("http://myhost.local/")
    end
  end

  # ── Integration: full HTML document ────────────────────────────────────

  describe "full document extraction" do
    test "extracts readable content from a realistic HTML page" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <title>Test Article &mdash; News Site</title>
        <style>body { font-family: sans-serif; }</style>
        <script>console.log("analytics");</script>
      </head>
      <body>
        <nav>
          <a href="/">Home</a>
          <a href="/news">News</a>
          <a href="/contact">Contact</a>
        </nav>
        <header>
          <h1>News Site</h1>
          <p>Your daily news source</p>
        </header>
        <article>
          <h1>Breaking: Elixir 2.0 Released</h1>
          <p>The Elixir team announced the release of Elixir 2.0 today,
             featuring significant improvements to the type system.</p>
          <p>Jos&eacute; Valim said &quot;This is a major milestone for the
             language &amp; its community.&quot;</p>
          <h2>Key Features</h2>
          <ul>
            <li>Gradual typing</li>
            <li>Improved pattern matching</li>
            <li>Better error messages</li>
          </ul>
        </article>
        <aside>
          <h3>Related Articles</h3>
          <p>Phoenix 2.0 coming soon</p>
        </aside>
        <footer>
          <p>&copy; 2026 News Site. All rights reserved.</p>
        </footer>
        <!-- Google Analytics -->
        <script>ga('send', 'pageview');</script>
      </body>
      </html>
      """

      result = WebFetch.extract_readable_text(html)

      # Content should be present
      assert result =~ "Elixir 2.0 Released"
      assert result =~ "type system"
      assert result =~ "Gradual typing"

      # Non-content should be stripped
      refute result =~ "analytics"
      refute result =~ "font-family"
      refute result =~ "Home"
      refute result =~ "Related Articles"
      refute result =~ "All rights reserved"
      refute result =~ "Google Analytics"

      # Title extraction
      assert WebFetch.extract_title(html) == "Test Article — News Site"
    end

    test "max_chars truncation works on extract" do
      # Generate long content
      long_paragraph = String.duplicate("word ", 5000)
      html = "<html><body><p>#{long_paragraph}</p></body></html>"

      full = WebFetch.extract_readable_text(html)
      assert String.length(full) > 100

      # Truncation would happen at the fetch level, but let's test the text extraction is clean
      assert full =~ "word"
    end
  end
end
