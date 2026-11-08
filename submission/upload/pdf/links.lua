-- Relative links (to files in the repository) become plain text with the path in brackets:
-- the PDF is read standalone. http(s)/mailto links and in-document anchors are kept.
function Link(el)
  local t = el.target or ""
  if t:match("^https?://") or t:match("^mailto:") or t:match("^#") then
    return el
  end
  local out = {}
  for _, x in ipairs(el.content) do table.insert(out, x) end
  local txt = pandoc.utils.stringify(el.content)
  if t ~= "" and t ~= txt then
    table.insert(out, pandoc.Str("（" .. t .. "）"))
  end
  return out
end

-- Raw HTML in the Markdown: <br> inside table cells becomes a line break; any other inline tag
-- (e.g. a placeholder such as <file> written outside backticks) is kept as literal text.
function RawInline(el)
  if el.format == "html" then
    if el.text:match("^<br%s*/?>$") then return pandoc.LineBreak() end
    return pandoc.Str(el.text)
  end
end

function RawBlock(el)
  if el.format == "html" then
    if el.text:match("^<!%-%-") then return {} end
    return pandoc.Para({pandoc.Str(el.text)})
  end
end
