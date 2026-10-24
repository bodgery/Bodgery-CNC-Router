-- VECTRIC LUA SCRIPT
--[[
  CribbageBoardReviewReport.lua

  Pre-flight review checker for the "Small Cribbage Board" student
  project (double-sided machining class project). Run from VCarve's
  Gadgets menu against a student's open file before their machine
  appointment.

  Renamed from the original generic "ProjectReviewReport.lua" on
  2026-08-08 once separate per-project gadgets were adopted (Box and
  Clock projects to follow as their own gadgets, reusing this file as
  a starting template). Checks below are specific to the Cribbage
  Board project and its "Instructions for Small Cribbage Board" doc.

  Status: TESTED against multiple live student files, including one
  with a real RPM/feed/plunge error on peg holes and V-grooves, and
  that student's corrected file.
  Confirmed working end to end. Two known SDK quirks worked around:
    - job:CopyToClipboard() reports success but the text never
      actually reaches the Windows clipboard - not used, see NOTE
      further down.
    - Toolpath objects don't support the == operator ("__eq: No such
      operator defined") - identity is tracked via
      GetToolpathIdString() instead of comparing tp objects directly.

  REPORT ARCHITECTURE - rewritten 2026-08-13, replacing the original
  "!!"/"~~" TEXT MARKER design:
    Previously, a line's severity (error vs warning) was encoded as a
    literal substring ("!!" or "~~") glued onto the front of the
    message text itself, and every consumer (the HTML colorizer, the
    compact-summary filter) had to search the text for that substring
    to figure out what it meant. This looked "quick and dirty" but
    fine at first - it broke down hard once "~~" (which is ALSO
    Markdown strikethrough syntax) hit a real Windows clipboard
    conversion step during copy/paste: two separate, unrelated "~~"
    warning lines anywhere in the same copied selection got treated as
    an opening/closing strikethrough PAIR, silently corrupting (or on
    one real test, swallowing dozens of lines of) the copied text.
    Stripping the marker out of the DISPLAYED text before copying
    fixed the immediate symptom, but the underlying design flaw - a
    piece of real structured data (severity) encoded as parseable text
    - was still there and could bite again with a different marker
    choice or a different consumer.

    Every Format*Report() function below now returns a Report object
    (see NewReport()) instead of a concatenated string: an ordered
    list of {text=, severity=} records, where severity is a real Lua
    value (nil / "warning" / "error"), never text. No line's severity
    is ever encoded IN its text, so there is nothing for a Markdown-
    aware (or any other) text-processing step to misinterpret - this
    isn't a narrower workaround for the "~~" bug, it eliminates the
    entire class of bug the "~~" incident was an instance of.
    Reports also track their own .flagged state automatically (true
    as soon as any "warning" or "error" line is added, or as soon as
    a sub-report with .flagged=true is Append()ed) - main() no longer
    needs to separately track and OR together a dozen *_flagged locals.

  What it reports, for the currently open job:
    1. Job name + units
    2. Material width/height/thickness vs. the 3.5" x 17" x 0.75" stock
       specified in the instructions, with a tolerance-based check for
       hand-measured actual thickness, plus a separate "exactly the
       default value" check (student likely never measured at all)
    3. Z-zero (must be material surface) and XY-origin (must be
       centred), per the instructions
    4. Job type (must be Double-Sided)
    5. Dowel hole symmetry AND exact diameter (0.510" +/- 0.005") -
       these register the top/bottom alignment when the workpiece is
       flipped, so both size and placement matter
    6. Web width on both long Y-edges (min 0.25", per instructions),
       workpiece centering in the stock (X and Y, checked directly on
       the cutout toolpath's own workpiece geometry - no separate
       dowel-hole-based centering check needed), and lead-in/lead-out
       encroachment for the final cutout toolpath - flags a lead that
       crosses into/through a web, leaves the stock entirely, or exits
       through the end but travels more than 1" past the workpiece
       edge (risking the dowel holes). Ported from the "Cutout Web /
       Lead Check" diagnostic gadget after validation against known-
       good, known-bad, through-end, crosses-web, and off-stock test
       files - added following a real incident (a student's lead-in
       severed a hold-down web mid-cut)
    7. Every layer: name, object count, visible/locked
    8. Every toolpath: name, tool name/diameter/number, feeds/speeds
    9. All 7 expected toolpaths (peg holes, V-grooves, dowel holes,
       magnet pockets, shallow pocket, deep pocket, part cutout) are
       identified OBJECTIVELY by side + depth/overcut (not by name,
       which students set inconsistently), then checked against the
       instructions' RPM/feed/plunge/tool diameter
    10. Any toolpath that cuts through material unexpectedly, OR that
       doesn't match any of the 7 known operations (e.g. a student's
       extra personal-touch toolpath like engraved initials) - the
       latter is flagged as UNRECOGNIZED even if you've already seen
       and approved it, specifically so it doesn't slip past unnoticed
       on a future file

  Output is an HTML dialog (see NOTE near the bottom of main() for why
  not a plain message box). Stays compact by default: a WARNINGS
  section (amber) and an ERRORS section (red), each a plain bulleted
  list with NO severity-marker text of any kind - see REPORT
  ARCHITECTURE above. Set VERBOSE_OUTPUT = true below to see the full
  report instead (every check, passing and flagged, in original order,
  still colored by severity but via the Report's real severity field,
  not text search) - useful when debugging the script itself or
  double-checking an identification. No separate gadget needed for
  this - edit the flag, save, re-run the same gadget.
]]

require "strict"

-- GADGET VERSION - shown in the report header so any report can be
-- traced to the exact file that produced it. Scheme (Mike,
-- 2026-10-14), versioned PER GADGET, bumped by hand in the SAME commit
-- as the change (no build step, and VCarve's Lua sandbox can't reach
-- git, so this can't be generated automatically):
--   third digit  - any commit that changes this file
--   second digit - any commit that changes the report's OUTPUT, fixes
--                  included (resets the third digit to 0)
--   first digit  - ready to share beyond Steve; 0.x means beta
g_version = "0.10.0"
g_title = "Cribbage Board Review Report"
g_width = 800
g_height = 650
g_html_file = "CribbageBoardReviewReport.html"

-- Escapes text for safe insertion into the HTML dialog's innerHTML.
local function EscapeHtml(s)
    s = tostring(s)
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    return s
end

--------------------------------------------------------------------
-- REPORT: a small builder for an ordered list of {text=, severity=}
-- records, replacing the old "concatenated string with '!!'/'~~'
-- markers glued onto the text" design - see the REPORT ARCHITECTURE
-- note at the top of this file for why.
--
-- severity is nil (informational/passing), "warning", or "error".
-- Every Format*Report() function below builds and returns one of
-- these; main() assembles them with :Append().
--------------------------------------------------------------------
function NewReport()
    local report = { records = {}, flagged = false }

    -- Adds one line. severity is optional (nil = informational).
    function report:Line(text, severity)
        table.insert(self.records, { text = text, severity = severity })
        if severity == "warning" or severity == "error" then
            self.flagged = true
        end
    end

    -- Adds a blank spacer line (informational, never flagged).
    function report:Blank()
        table.insert(self.records, { text = "", severity = nil })
    end

    -- Adds a section header: the title line plus a fixed-width
    -- underline, matching every section's look throughout this file.
    function report:Header(text)
        self:Line(text)
        self:Line(string.rep("-", 40))
    end

    -- Appends every record from another Report into this one, and
    -- merges its flagged state - the standard way main() assembles
    -- the full report out of each check's own Report.
    function report:Append(other)
        for _, rec in ipairs(other.records) do
            table.insert(self.records, rec)
        end
        if other.flagged then
            self.flagged = true
        end
    end

    return report
end

-- Renders a flat list of {text=, severity=} records as HTML for the
-- dialog's AddLabelField - real <br> tags render correctly there, but
-- raw "\n" does not (validated during earlier diagnostic work).
-- Leading spaces in text are preserved via &nbsp; (plain spaces
-- collapse in HTML) - used for the FULL/verbose view's visual
-- indentation, purely cosmetic, no meaning attached to it.
--
-- Consecutive same-severity records are grouped into ONE <b>...</b>
-- block (joined internally by <br>) rather than one tag per record,
-- for a tidier rendered look - this is no longer a correctness fix
-- (unlike the old marker-text design, there is now no marker
-- substring anywhere in the text for anything to misinterpret,
-- regardless of tag structure), just cleaner HTML.
local function RecordsToHtml(records)
    local out = {}
    local current_severity = nil
    local current_run = {}

    local function FlushRun()
        if #current_run == 0 then return end
        local joined = table.concat(current_run, "<br>\n")
        if current_severity == "warning" then
            table.insert(out, "<b style=\"color:#b35900;\">" .. joined .. "</b>")
        elseif current_severity == "error" then
            table.insert(out, "<b style=\"color:#b00000;\">" .. joined .. "</b>")
        else
            table.insert(out, joined)
        end
        current_run = {}
    end

    for _, rec in ipairs(records) do
        local text = rec.text or ""
        local leading_spaces = text:match("^( *)") or ""
        local rest = text:sub(#leading_spaces + 1)
        local nbsp_prefix = string.rep("&nbsp;", #leading_spaces)
        local html_line = nbsp_prefix .. EscapeHtml(rest)

        if rec.severity ~= current_severity then
            FlushRun()
            current_severity = rec.severity
        end
        table.insert(current_run, html_line)
    end
    FlushRun()

    return table.concat(out, "<br>\n")
end

-- Renders one compact-summary section (WARNINGS or ERRORS) as a
-- colored header plus a plain HTML bullet list - each item is just
-- rec.text with leading whitespace trimmed, EscapeHtml'd, wrapped in
-- <li>. No severity-marker text is ever written into this HTML, by
-- construction (severity lives in rec.severity, never in rec.text) -
-- see REPORT ARCHITECTURE at the top of this file.
local function BulletSectionHtml(title, records, color)
    local li_parts = {}
    for _, rec in ipairs(records) do
        local trimmed = (rec.text or ""):gsub("^%s*", "")
        table.insert(li_parts, "<li>" .. EscapeHtml(trimmed) .. "</li>")
    end
    return "<br>\n<div style=\"color:" .. color .. ";\"><b>" .. title .. "</b>" ..
        "<ul style=\"margin:2px 0 10px 0; padding-left:20px;\">" ..
        table.concat(li_parts, "\n") .. "</ul></div>"
end

-- Get a comparable string identity for a Toolpath, robust to whether
-- tp.Id is already a luaUUID (has :AsString() directly) or a raw UUID
-- (needs wrapping in a fresh luaUUID via :SetId() first - same pattern
-- CadObject uses for its separate .Id/.RawId properties). Tries both;
-- returns nil if neither works, so callers can fail safe rather than
-- silently mismatch.
function GetToolpathIdString(tp)
    local ok1, result1 = pcall(function() return tp.Id:AsString() end)
    if ok1 and result1 then return result1 end

    local ok2, result2 = pcall(function()
        local wrapper = luaUUID()
        wrapper:SetId(tp.Id)
        return wrapper:AsString()
    end)
    if ok2 and result2 then return result2 end

    return nil
end

--------------------------------------------------------------------
-- EXPECTED PROJECT SETUP (Small Cribbage Board)
-- Source: "Instructions for Small Cribbage Board" (Google Doc)
--------------------------------------------------------------------
EXPECTED_WIDTH       = 17.0   -- stock long dimension, along X (inches)
EXPECTED_HEIGHT      = 3.5    -- stock short dimension, along Y (inches)
DEFAULT_THICKNESS    = 0.75   -- default stock thickness (inches)
THICKNESS_TOLERANCE  = 0.050  -- flag if actual thickness differs from
                               -- default by more than this
EXACT_DEFAULT_EPSILON = 0.0005  -- inches - float-safe equality; detects
                                  -- "suspiciously exact" (student likely
                                  -- never measured their actual stock),
                                  -- separate from the "suspiciously
                                  -- different" check above.

-- Dowel pin holes: student draws these by hand (not from an imported
-- DXF layer), sized "slightly larger than the dowels" (1/2" steel dowel
-- pins). The detection band below is deliberately wide, just to find
-- candidate circles at all. Once found, each is checked against the
-- exact specified diameter with a much tighter fit tolerance, since a
-- loose or tight hole affects how well the dowel pins register the
-- workpiece between the top and bottom cuts.
DOWEL_HOLE_DIA_MIN     = 0.45    -- inches (detection band, wide)
DOWEL_HOLE_DIA_MAX     = 0.60    -- inches (detection band, wide)
DOWEL_HOLE_DIA_EXACT   = 0.510   -- inches - specified hole diameter
DOWEL_HOLE_DIA_TOL     = 0.005   -- inches - fit tolerance on exact diameter
DOWEL_SYMMETRY_TOL     = 0.010   -- inches - max allowed mirror-position error

-- Cutout toolpath identification - shared single source of truth for
-- BOTH the through-cut spec below (EXPECTED_THROUGH_CUTS[1]) and the
-- web-width/lead-encroachment checks further down, so the two never
-- drift apart.
CUTOUT_SIDE_KEYWORD      = "bottom"
CUTOUT_OVERCUT_EXPECTED  = 0.020
CUTOUT_OVERCUT_TOLERANCE = 0.010

-- Float slack on overcut tolerance comparisons (2026-10-14, v0.10.0),
-- ported from BoxProjectReviewReport.lua. Overcut = depth - thickness,
-- both floats, so a value meant to sit exactly on the tolerance edge
-- (e.g. 0.010") can compute as 0.0099999... and fall outside. Here
-- that matters MORE than in Box/Clock: overcut is used to IDENTIFY the
-- through-cut toolpaths, so a boundary miss means the cutout isn't
-- recognized at all (cascading into "could not identify", "CUTS
-- THROUGH MATERIAL", and skipped web/lead checks). 0.001" per Mike:
-- physically negligible for spoilboard overcut.
BOUNDARY_EPSILON = 0.001  -- inches

-- Web width / lead-in-out encroachment checks - ported from the
-- "Cutout Web / Lead Check" diagnostic gadget, validated there against
-- known-good, known-bad, through-end, crosses-web, and off-stock test
-- files before being ported here.
MIN_WEB_WIDTH          = 0.25   -- inches - fixed design requirement:
                                  -- (3.5" stock - 2.5" board)/2 - 0.25"
                                  -- bit dia = 0.25" (see "Instructions
                                  -- for Small Cribbage Board")
WEB_WIDTH_TOLERANCE    = 0.005  -- inches - float/measurement slop; only
                                  -- flag if actual_web is below
                                  -- MIN_WEB_WIDTH by more than this
POINT_TOLERANCE        = 0.001  -- inches - same float-boundary slop,
                                  -- applied to lead-point-vs-box compares
MAX_END_EXIT_DISTANCE  = 1.0    -- inches - leads exiting through the end
                                  -- must not travel further than this past
                                  -- the workpiece edge, to stay clear of
                                  -- the dowel holes near the ends
CENTERING_TOLERANCE    = 0.010  -- inches - max allowed offset between the
                                  -- workpiece's center and the stock's
                                  -- center, on either axis (same order of
                                  -- magnitude as DOWEL_SYMMETRY_TOL above)

-- Set to true to see the FULL report (every layer, every toolpath,
-- all passing checks included) instead of just the flagged issues.
-- No separate gadget needed - flip this, save, and re-run the same
-- gadget from the menu. Flip back to false afterward to go back to
-- the compact summary. The dialog is scrollable, so full mode is
-- usable for spot-checking, just longer to scroll through.
VERBOSE_OUTPUT = false

-- Toolpaths EXPECTED to cut all the way through the material, listed
-- here instead of relying on toolpath names (too fragile - students
-- name things inconsistently). Each entry is identified OBJECTIVELY by
-- two SDK-checkable properties: which SIDE it's on (Toolpath.SideId,
-- translated via job:GetSideName()) and the SIZE of its overcut past
-- material thickness. These two together should be unique per entry,
-- since no other toolpath on that side is expected to cut through at
-- all. There's no documented "toolpath type" (Profile vs Pocket)
-- property in the SDK, so side + overcut magnitude is the best
-- available fingerprint - not a check for "is a Profile operation".
--
-- Once identified, rpm/feed/plunge/tool_dia (any of which may be nil
-- to skip that check) are validated against the instructions too.
--
--   label             - just for messages, doesn't affect matching
--   side_keyword      - matched case-insensitively (substring) against
--                        job:GetSideName(tp.SideId)
--   overcut_expected  - inches past material thickness
--   overcut_tolerance - inches - how far from overcut_expected still counts
--   rpm/feed/plunge/tool_dia_expected + _tolerance - nil to skip that check
EXPECTED_THROUGH_CUTS = {
    {
        label = "final part cutout",
        side_keyword = CUTOUT_SIDE_KEYWORD,
        overcut_expected = CUTOUT_OVERCUT_EXPECTED,
        overcut_tolerance = CUTOUT_OVERCUT_TOLERANCE,
        rpm_expected = 18000, rpm_tolerance = 250,
        feed_expected = 110, feed_tolerance = 5,
        plunge_expected = 55, plunge_tolerance = 5,
        tool_dia_expected = 0.250, tool_dia_tolerance = 0.010,  -- 1/4" compression bit
    },
    {
        label = "dowel hole alignment bore",
        side_keyword = "top",
        overcut_expected = 0.500,   -- bores 0.5" into the backer/wasteboard
                                     -- for top/bottom alignment when flipping -
                                     -- VCarve has no concept of the backer
                                     -- board, so this has to be told to it
                                     -- explicitly rather than inferred
        overcut_tolerance = 0.100,
        rpm_expected = 18000, rpm_tolerance = 250,
        feed_expected = 110, feed_tolerance = 5,
        plunge_expected = 55, plunge_tolerance = 5,
        tool_dia_expected = nil,  -- instructions don't state a tool diameter
                                   -- for this operation, so this is skipped
    },
}

-- Toolpaths that should NOT cut through the material, identified by
-- side + a SPECIFIC absolute cut depth rather than overcut (each of
-- these depths is far enough apart from the others that this should
-- be unambiguous). Same field meanings as EXPECTED_THROUGH_CUTS, but
-- depth_expected/tolerance replaces overcut_expected/tolerance.
NON_THROUGH_CUT_SPECS = {
    {
        label = "peg holes (drilling)",
        side_keyword = "top",
        depth_expected = 0.375, depth_tolerance = 0.010,
        rpm_expected = 7500, rpm_tolerance = 250,
        feed_expected = nil,  -- drilling - feed rate isn't meaningfully
                               -- comparable the way it is for profile/pocket
                               -- toolpaths, so this is skipped
        plunge_expected = 19, plunge_tolerance = 2,
        tool_dia_expected = 0.125, tool_dia_tolerance = 0.010,  -- 1/8" drill
    },
    {
        label = "V-Grooves",
        side_keyword = "top",
        depth_expected = 0.0197, depth_tolerance = 0.005,
        rpm_expected = 14000, rpm_tolerance = 250,
        feed_expected = 80, feed_tolerance = 5,
        plunge_expected = 30, plunge_tolerance = 5,
        tool_dia_expected = nil,  -- v-bit diameter isn't a meaningful
                                   -- spec here (it's the ANGLE that
                                   -- matters, which isn't exposed via
                                   -- Tool.ToolDia) - skipped
    },
    {
        label = "magnet pockets",
        side_keyword = "bottom",
        depth_expected = 0.1574, depth_tolerance = 0.010,
        rpm_expected = 21000, rpm_tolerance = 250,
        feed_expected = 60, feed_tolerance = 5,
        plunge_expected = 30, plunge_tolerance = 5,
        tool_dia_expected = 0.125, tool_dia_tolerance = 0.010,  -- 1/8" downcut
    },
    {
        label = "shallow pocket",
        side_keyword = "bottom",
        depth_expected = 0.0787, depth_tolerance = 0.010,
        rpm_expected = 18000, rpm_tolerance = 250,
        feed_expected = 110, feed_tolerance = 5,
        plunge_expected = 55, plunge_tolerance = 5,
        tool_dia_expected = 0.250, tool_dia_tolerance = 0.010,  -- 1/4" downcut
    },
    {
        label = "deep pocket",
        side_keyword = "bottom",
        depth_expected = 0.5463, depth_tolerance = 0.010,
        rpm_expected = 18000, rpm_tolerance = 250,
        feed_expected = 110, feed_tolerance = 5,
        plunge_expected = 55, plunge_tolerance = 5,
        tool_dia_expected = 0.250, tool_dia_tolerance = 0.010,  -- 1/4" downcut
    },
}

-- Compares a toolpath's actual tool params against a spec's expected
-- values (any expected field left nil skips that particular check).
-- Returns a list of plain mismatch strings (empty if everything
-- matches) - callers are responsible for tagging these "error" when
-- adding them to a Report, since this function has no report of its
-- own to build.
function CheckToolParams(tool, spec)
    local mismatches = {}
    if not tool then
        table.insert(mismatches, "no tool assigned")
        return mismatches
    end

    if spec.rpm_expected and math.abs(tool.SpindleSpeed - spec.rpm_expected) > spec.rpm_tolerance then
        table.insert(mismatches, string.format(
            "RPM expected=%.0f actual=%.0f", spec.rpm_expected, tool.SpindleSpeed
        ))
    end
    if spec.feed_expected and math.abs(tool.FeedRate - spec.feed_expected) > spec.feed_tolerance then
        table.insert(mismatches, string.format(
            "feed expected=%.1f actual=%.1f", spec.feed_expected, tool.FeedRate
        ))
    end
    if spec.plunge_expected and math.abs(tool.PlungeRate - spec.plunge_expected) > spec.plunge_tolerance then
        table.insert(mismatches, string.format(
            "plunge expected=%.1f actual=%.1f", spec.plunge_expected, tool.PlungeRate
        ))
    end
    if spec.tool_dia_expected and math.abs(tool.ToolDia - spec.tool_dia_expected) > spec.tool_dia_tolerance then
        table.insert(mismatches, string.format(
            "tool dia expected=%.3f actual=%.3f", spec.tool_dia_expected, tool.ToolDia
        ))
    end

    return mismatches
end

function FormatMaterialSetupReport(mtl_block)
    local r = NewReport()
    r:Header("MATERIAL SETUP CHECKS")

    -- Width / height vs. instructions
    if EXPECTED_WIDTH > 0 and EXPECTED_HEIGHT > 0 then
        if math.abs(mtl_block.Width - EXPECTED_WIDTH) > 0.001 then
            r:Line(string.format(
                "  WIDTH MISMATCH: expected=%.3f actual=%.3f",
                EXPECTED_WIDTH, mtl_block.Width
            ), "error")
        end
        if math.abs(mtl_block.Height - EXPECTED_HEIGHT) > 0.001 then
            r:Line(string.format(
                "  HEIGHT MISMATCH: expected=%.3f actual=%.3f",
                EXPECTED_HEIGHT, mtl_block.Height
            ), "error")
        end
    else
        r:Line("  (width/height check skipped - EXPECTED_WIDTH/HEIGHT not set)")
    end

    -- Thickness vs. default, with tolerance for a hand-measured actual
    local thickness_diff = mtl_block.Thickness - DEFAULT_THICKNESS
    if math.abs(thickness_diff) > THICKNESS_TOLERANCE then
        r:Line(string.format(
            "  THICKNESS differs from default by %.3f: default=%.3f actual=%.3f (bring to attention - may be a measured workpiece)",
            thickness_diff, DEFAULT_THICKNESS, mtl_block.Thickness
        ), "error")
    end

    -- Exact-default detection - separate from the tolerance check above.
    -- Real measured stock essentially never comes out to EXACTLY 0.75" -
    -- a value this precise almost always means the student left the
    -- default in place and never measured their actual material.
    if math.abs(thickness_diff) < EXACT_DEFAULT_EPSILON then
        r:Line(string.format(
            "  THICKNESS IS EXACTLY %.3f (the default) - has the student measured their actual stock?",
            DEFAULT_THICKNESS
        ), "warning")
    end

    -- Z-zero: should be material surface (Z_TOP), not centre or bottom
    local z_origin = mtl_block.ZOrigin
    local z_origin_text = "unknown"
    if z_origin == MaterialBlock.Z_TOP then
        z_origin_text = "Top of Material (correct)"
    elseif z_origin == MaterialBlock.Z_CENTRE then
        z_origin_text = "Centre of Material"
    elseif z_origin == MaterialBlock.Z_BOTTOM then
        z_origin_text = "Bottom of Material"
    end
    r:Line("  Z-Zero: " .. z_origin_text)
    if z_origin ~= MaterialBlock.Z_TOP then
        r:Line("  Z-ZERO should be material surface, not " .. z_origin_text, "error")
    end

    -- XY origin: should be centred in the workpiece
    local xy_origin = mtl_block.XYOrigin
    local xy_origin_text = "unknown"
    if xy_origin == MaterialBlock.CENTRE then
        xy_origin_text = "Centre (correct)"
    elseif xy_origin == MaterialBlock.BLC then
        xy_origin_text = "Bottom Left Corner"
    elseif xy_origin == MaterialBlock.BRC then
        xy_origin_text = "Bottom Right Corner"
    elseif xy_origin == MaterialBlock.TRC then
        xy_origin_text = "Top Right Corner"
    elseif xy_origin == MaterialBlock.TLC then
        xy_origin_text = "Top Left Corner"
    end
    r:Line("  XY-Origin: " .. xy_origin_text)
    if xy_origin ~= MaterialBlock.CENTRE then
        r:Line("  XY-ORIGIN should be centred in workpiece, not " .. xy_origin_text, "error")
    end

    return r
end

function FormatJobTypeReport(job)
    local r = NewReport()
    r:Blank()
    r:Header("JOB TYPE CHECK")

    if job.IsDoubleSided then
        r:Line("  Job type: Double-Sided (correct)")
    else
        r:Line("  JOB TYPE: expected Double-Sided, this job is not set up as two-sided", "error")
    end

    return r
end

-- Find candidate dowel-hole circles: small, roughly-round closed
-- contours in the expected diameter band. Returns a list of
-- {x=, y=, dia=, layer_name=} for every candidate found on any
-- non-system layer.
function FindDowelHoleCandidates(job)
    local candidates = {}
    local layer_manager = job.LayerManager
    local layer_pos = layer_manager:GetHeadPosition()

    while layer_pos ~= nil do
        local layer
        layer, layer_pos = layer_manager:GetNext(layer_pos)

        if not layer.IsSystemLayer then
            local obj_pos = layer:GetHeadPosition()
            while obj_pos ~= nil do
                local obj
                obj, obj_pos = layer:GetNext(obj_pos)

                if obj.ClassName == "vcCadContour" or obj.ClassName == "vcCadPolyline" then
                    local ok, contour = pcall(function() return obj:GetContour() end)
                    if ok and contour and contour.IsClosed then
                        local bb = contour.BoundingBox2D
                        if bb and not bb.IsInvalid then
                            -- roughly circular: width and height nearly equal
                            local roundness_diff = math.abs(bb.XLength - bb.YLength)
                            local avg_dia = (bb.XLength + bb.YLength) / 2.0
                            if roundness_diff < 0.01
                               and avg_dia >= DOWEL_HOLE_DIA_MIN
                               and avg_dia <= DOWEL_HOLE_DIA_MAX then
                                local centre = bb.Centre
                                table.insert(candidates, {
                                    x = centre.x,
                                    y = centre.y,
                                    dia = avg_dia,
                                    layer_name = layer.Name
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    return candidates
end

function FormatDowelHoleSymmetryReport(job)
    local r = NewReport()
    r:Blank()
    r:Header("DOWEL HOLE SYMMETRY CHECK")

    local candidates = FindDowelHoleCandidates(job)

    if #candidates == 0 then
        r:Line("  NO dowel-hole-sized circles found (expected 2, dia "
            .. string.format("%.2f-%.2f\")", DOWEL_HOLE_DIA_MIN, DOWEL_HOLE_DIA_MAX), "error")
    elseif #candidates == 1 then
        r:Line(string.format(
            "  Only 1 dowel-hole-sized circle found at (%.3f, %.3f) dia=%.3f - expected 2",
            candidates[1].x, candidates[1].y, candidates[1].dia
        ), "error")
    elseif #candidates > 2 then
        r:Line(string.format(
            "  %d dowel-hole-sized circles found - expected exactly 2, can't determine which are the dowel holes",
            #candidates
        ), "error")
        for i, c in ipairs(candidates) do
            r:Line(string.format(
                "     candidate %d: (%.3f, %.3f) dia=%.3f layer='%s'",
                i, c.x, c.y, c.dia, c.layer_name
            ))
        end
    else
        -- exactly 2 candidates - check mirror symmetry about X = 0
        -- (job XY origin should already be centred per the material setup check)
        local a, b = candidates[1], candidates[2]
        local x_symmetry_err = math.abs(a.x + b.x)   -- should mirror: a.x = -b.x
        local y_alignment_err = math.abs(a.y - b.y)  -- should share same Y

        r:Line(string.format("  Hole 1: (%.3f, %.3f) dia=%.3f", a.x, a.y, a.dia))
        r:Line(string.format("  Hole 2: (%.3f, %.3f) dia=%.3f", b.x, b.y, b.dia))

        -- Exact diameter check - fit matters for dowel registration
        local a_dia_err = math.abs(a.dia - DOWEL_HOLE_DIA_EXACT)
        local b_dia_err = math.abs(b.dia - DOWEL_HOLE_DIA_EXACT)
        if a_dia_err > DOWEL_HOLE_DIA_TOL then
            r:Line(string.format(
                "  Hole 1 DIAMETER off spec: expected=%.3f actual=%.3f (tolerance=%.3f)",
                DOWEL_HOLE_DIA_EXACT, a.dia, DOWEL_HOLE_DIA_TOL
            ), "error")
        end
        if b_dia_err > DOWEL_HOLE_DIA_TOL then
            r:Line(string.format(
                "  Hole 2 DIAMETER off spec: expected=%.3f actual=%.3f (tolerance=%.3f)",
                DOWEL_HOLE_DIA_EXACT, b.dia, DOWEL_HOLE_DIA_TOL
            ), "error")
        end

        if x_symmetry_err > DOWEL_SYMMETRY_TOL or y_alignment_err > DOWEL_SYMMETRY_TOL then
            r:Line(string.format(
                "  DOWEL HOLES NOT SYMMETRIC: X mirror error=%.4f, Y alignment error=%.4f (tolerance=%.3f)",
                x_symmetry_err, y_alignment_err, DOWEL_SYMMETRY_TOL
            ), "error")
            r:Line("     Top/bottom features will not align correctly when the workpiece is flipped.")
            r:Line("     Fix: draw one hole, align it to the board, then Mirror it to create the other.")
        elseif a_dia_err <= DOWEL_HOLE_DIA_TOL and b_dia_err <= DOWEL_HOLE_DIA_TOL then
            r:Line("  Symmetric and correct diameter")
        end
    end

    return r
end

-- Convert a value measured in the tool's units to the block material's
-- units (only relevant if a student's tool library uses mm while the
-- job is in inches, or vice versa).
function ConvertUnitsFrom(value, tool, blockmaterial)
    if (tool.InMM == blockmaterial.InMM) then return value end
    if (tool.InMM) then return value / 25.4 end
    return value * 25.4
end

-- Find the largest closed contour on any non-system layer (validated
-- workpiece-identification technique, ported from the "Cutout Web /
-- Lead Check" diagnostic gadget).
function FindWorkpieceBoundingBox(job)
    local best_box = nil
    local best_area = -1

    local layer_manager = job.LayerManager
    local lpos = layer_manager:GetHeadPosition()
    while lpos ~= nil do
        local layer
        layer, lpos = layer_manager:GetNext(lpos)

        local ok_sys, is_system = pcall(function() return layer.IsSystemLayer end)
        if ok_sys and not is_system then

            local opos = layer:GetHeadPosition()
            while opos ~= nil do
                local obj
                obj, opos = layer:GetNext(opos)

                local ok_contour, contour = pcall(function() return obj:GetContour() end)
                if ok_contour and contour ~= nil then
                    local ok_open, is_open = pcall(function() return contour.IsOpen end)
                    if ok_open and not is_open then
                        local ok_box, box = pcall(function() return obj:GetBoundingBox() end)
                        if ok_box and box ~= nil and not box.IsInvalid then
                            local area = box.XLength * box.YLength
                            if area > best_area then
                                best_area = area
                                best_box = box
                            end
                        end
                    end
                end
            end
        end
    end

    return best_box
end

-- Identify the cutout toolpath by side + overcut magnitude (same
-- objective-identification approach as EXPECTED_THROUGH_CUTS above,
-- using the SAME shared constants so the two never drift apart).
function FindCutoutToolpathForLeadCheck(job, mtl_block)
    local toolpath_mgr = ToolpathManager()
    if toolpath_mgr.IsEmpty then
        return nil, "no toolpaths in job"
    end

    local candidates = {}
    local pos = toolpath_mgr:GetHeadPosition()
    while pos ~= nil do
        local tp
        tp, pos = toolpath_mgr:GetNext(pos)

        local side_name = "unknown"
        local ok_side, side_result = pcall(function() return job:GetSideName(tp.SideId) end)
        if ok_side and side_result then side_name = side_result end

        local depth = nil
        local ok_stats, stats = pcall(function() return tp:Statistics() end)
        if ok_stats and stats and stats.IsValid then
            depth = mtl_block:CalcDepthFromAbsoluteZ(stats.MinimumZ)
        end

        if depth and string.find(string.lower(side_name), CUTOUT_SIDE_KEYWORD, 1, true) then
            local overcut = depth - mtl_block.Thickness
            if overcut > 0 and math.abs(overcut - CUTOUT_OVERCUT_EXPECTED) <= CUTOUT_OVERCUT_TOLERANCE + BOUNDARY_EPSILON then
                table.insert(candidates, tp)
            end
        end
    end

    if #candidates == 1 then
        return candidates[1], nil
    elseif #candidates == 0 then
        return nil, "could not identify cutout toolpath (expected " .. CUTOUT_SIDE_KEYWORD ..
                     " side, ~" .. string.format("%.3f", CUTOUT_OVERCUT_EXPECTED) .. "\" overcut)"
    else
        return nil, #candidates .. " toolpaths matched cutout criteria - ambiguous"
    end
end

-- CHECK 1 of the web/lead pair: actual structural web width on the two
-- long Y-edges (NOT the short X-ends near the dowel holes). Deducts
-- the FULL bit diameter (not the radius) because the cutout toolpath
-- profiles the OUTSIDE of the workpiece vector - the entire kerf is
-- removed from the waste side, not split across it.
function FormatWebWidthReport(workpiece_box, stock_box, bit_dia)
    local r = NewReport()
    r:Blank()
    r:Header("WEB WIDTH CHECK (min required " .. string.format("%.3f", MIN_WEB_WIDTH) .. "\")")

    if not bit_dia then
        r:Line("  (skipped - no bit diameter available)")
        return r
    end

    local top_gap = stock_box.MaxY - workpiece_box.MaxY
    local top_web = top_gap - bit_dia
    if top_web < (MIN_WEB_WIDTH - WEB_WIDTH_TOLERANCE) then
        r:Line(string.format("  TOP WEB TOO THIN: actual=%.4f  min=%.3f", top_web, MIN_WEB_WIDTH), "error")
    else
        r:Line(string.format("  Top edge web: %.4f  OK", top_web))
    end

    local bottom_gap = workpiece_box.MinY - stock_box.MinY
    local bottom_web = bottom_gap - bit_dia
    if bottom_web < (MIN_WEB_WIDTH - WEB_WIDTH_TOLERANCE) then
        r:Line(string.format("  BOTTOM WEB TOO THIN: actual=%.4f  min=%.3f", bottom_web, MIN_WEB_WIDTH), "error")
    else
        r:Line(string.format("  Bottom edge web: %.4f  OK", bottom_web))
    end

    return r
end

-- CHECK 2 of the web/lead pair: does the cutout toolpath's
-- FirstPoint/LastPoint encroach on a web, leave the stock entirely, or
-- run too far past the workpiece end (toward the dowel holes)? Points
-- are compared against an OFFSET box (workpiece vector expanded by the
-- bit radius) rather than the raw vector box, since the toolpath
-- profiles OUTSIDE the vector - a normal zero-lead-out stop otherwise
-- reads as a false-positive web crossing right at the corner.
function FormatLeadEncroachmentReport(cutout_tp, workpiece_box, stock_box, bit_dia)
    local r = NewReport()
    r:Blank()
    r:Header("LEAD-IN/LEAD-OUT ENCROACHMENT CHECK")

    if not bit_dia then
        r:Line("  (skipped - no bit diameter available for offset)")
        return r
    end

    local bit_radius = bit_dia / 2
    local offset_box = {
        MinX = workpiece_box.MinX - bit_radius,
        MaxX = workpiece_box.MaxX + bit_radius,
        MinY = workpiece_box.MinY - bit_radius,
        MaxY = workpiece_box.MaxY + bit_radius,
    }

    local function CheckPoint(label, pt)
        if pt.IsInvalid then
            r:Line("  " .. label .. ": INVALID", "error")
            return
        end

        local outside_stock = pt.X < stock_box.MinX - POINT_TOLERANCE
                            or pt.X > stock_box.MaxX + POINT_TOLERANCE
                            or pt.Y < stock_box.MinY - POINT_TOLERANCE
                            or pt.Y > stock_box.MaxY + POINT_TOLERANCE
        local within_x = pt.X >= offset_box.MinX - POINT_TOLERANCE
                      and pt.X <= offset_box.MaxX + POINT_TOLERANCE
        local outside_y = pt.Y < offset_box.MinY - POINT_TOLERANCE
                        or pt.Y > offset_box.MaxY + POINT_TOLERANCE
        local crosses_web = within_x and outside_y

        if outside_stock then
            r:Line(string.format(
                "  %s OUTSIDE STOCK: X=%.4f Y=%.4f - lead leaves the material",
                label, pt.X, pt.Y
            ), "error")
        elseif crosses_web then
            r:Line(string.format(
                "  %s CROSSES TOP/BOTTOM WEB: X=%.4f Y=%.4f",
                label, pt.X, pt.Y
            ), "error")
        elseif not within_x then
            local overrun = 0
            if pt.X < workpiece_box.MinX then
                overrun = workpiece_box.MinX - pt.X
            elseif pt.X > workpiece_box.MaxX then
                overrun = pt.X - workpiece_box.MaxX
            end
            if overrun > MAX_END_EXIT_DISTANCE + POINT_TOLERANCE then
                r:Line(string.format(
                    "  %s END EXIT TOO FAR: %.3f\" past workpiece edge (max %.3f\") - may run into dowel/screw holes",
                    label, overrun, MAX_END_EXIT_DISTANCE
                ), "error")
            else
                r:Line(string.format(
                    "  %s: OK - exits through end (%.3f\" past workpiece edge)", label, overrun
                ))
            end
        else
            r:Line(string.format("  %s: OK - within workpiece", label))
        end
    end

    CheckPoint("FirstPoint", cutout_tp.FirstPoint)
    CheckPoint("LastPoint ", cutout_tp.LastPoint)

    return r
end

-- Is the workpiece (the actual board contour, from FindWorkpieceBoundingBox)
-- centered in the stock on both X and Y? Uses the SAME workpiece_box/
-- stock_box already computed for the web-width check, rather than a
-- separate detection method (e.g. dowel hole positions) - checking
-- centering directly on the cutout geometry is sufficient.
function FormatWorkpieceCenteringReport(workpiece_box, stock_box)
    local r = NewReport()
    r:Blank()
    r:Header("WORKPIECE CENTERING CHECK")

    local stock_center_x = (stock_box.MinX + stock_box.MaxX) / 2
    local stock_center_y = (stock_box.MinY + stock_box.MaxY) / 2
    local workpiece_center_x = (workpiece_box.MinX + workpiece_box.MaxX) / 2
    local workpiece_center_y = (workpiece_box.MinY + workpiece_box.MaxY) / 2

    local x_err = workpiece_center_x - stock_center_x
    local y_err = workpiece_center_y - stock_center_y

    if math.abs(x_err) > CENTERING_TOLERANCE or math.abs(y_err) > CENTERING_TOLERANCE then
        r:Line(string.format(
            "  WORKPIECE NOT CENTERED: X offset=%.4f  Y offset=%.4f  (tolerance=%.3f)",
            x_err, y_err, CENTERING_TOLERANCE
        ), "error")
    else
        r:Line(string.format("  Centered: X offset=%.4f  Y offset=%.4f  OK", x_err, y_err))
    end

    return r
end

function FormatLayerReport(job)
    local r = NewReport()
    local layer_manager = job.LayerManager
    r:Header("LAYERS (" .. layer_manager.Count .. ")")

    local pos = layer_manager:GetHeadPosition()
    while pos ~= nil do
        local layer
        layer, pos = layer_manager:GetNext(pos)

        if not layer.IsSystemLayer then
            local vis = layer.Visible and "visible" or "HIDDEN"
            local lock = layer.Locked and "LOCKED" or "unlocked"
            r:Line(string.format(
                "  %-25s objects=%-4d %s, %s",
                layer.Name, layer.Count, vis, lock
            ))
        end
    end

    return r
end

function FormatToolpathReport(job, mtl_block)
    local r = NewReport()

    -- NOTE: ToolpathManager appears in the SDK as a singleton constructor,
    -- parallel to MaterialBlock(). If this line errors, that's the first
    -- thing to fix - try job.ToolpathManager instead.
    local tpm = ToolpathManager()

    r:Blank()
    r:Header("TOOLPATHS (" .. tpm.Count .. ")")

    if tpm.Count == 0 then
        r:Line("  ** NO TOOLPATHS FOUND IN JOB **", "error")
        return r
    end

    -- First pass: collect side name + depth-below-surface for every
    -- toolpath, so we can identify each expected operation objectively
    -- before deciding what to flag.
    -- NOTE: Toolpath objects don't support the == operator (confirmed
    -- via "__eq: No such operator defined" on a live run) - so identity
    -- is tracked via tp.Id:AsString() rather than comparing tp objects
    -- directly.
    local tp_data = {}
    local pos = tpm:GetHeadPosition()
    while pos ~= nil do
        local tp
        tp, pos = tpm:GetNext(pos)

        local side_name = "unknown"
        local ok_side, side_result = pcall(function() return job:GetSideName(tp.SideId) end)
        if ok_side and side_result then
            side_name = side_result
        end

        local depth_below_surface = nil
        local ok_stats, stats = pcall(function() return tp:Statistics() end)
        if ok_stats and stats and stats.IsValid then
            depth_below_surface = mtl_block:CalcDepthFromAbsoluteZ(stats.MinimumZ)
        end

        local id_str = GetToolpathIdString(tp)

        table.insert(tp_data, {
            tp = tp,
            id_str = id_str,
            tool = tp.Tool,
            side_name = side_name,
            depth = depth_below_surface,
        })
    end

    -- Identify each expected through-cut in EXPECTED_THROUGH_CUTS by
    -- side + overcut magnitude. Builds a lookup of exempted toolpath
    -- id_str -> label, used in the second pass below to decide what
    -- to flag. recognized_ids tracks every toolpath matched by ANY
    -- spec (through-cut or not), so leftover toolpaths not matching
    -- any of the 7 expected operations can be flagged as extras below
    -- (e.g. a student's added personal-touch toolpath you'd want to
    -- know about, even if you already approved it).
    local exempted_ids = {}
    local recognized_ids = {}

    for _, spec in ipairs(EXPECTED_THROUGH_CUTS) do
        local candidates = {}
        for _, d in ipairs(tp_data) do
            if d.depth and string.find(string.lower(d.side_name), spec.side_keyword, 1, true) then
                local overcut = d.depth - mtl_block.Thickness
                if overcut > 0 and math.abs(overcut - spec.overcut_expected) <= spec.overcut_tolerance + BOUNDARY_EPSILON then
                    table.insert(candidates, d)
                end
            end
        end

        if #candidates == 1 then
            local d = candidates[1]
            if d.id_str then
                exempted_ids[d.id_str] = spec.label
                recognized_ids[d.id_str] = spec.label
                r:Line(string.format(
                    "  Identified %s: '%s' (%s side, overcut=%.3f)",
                    spec.label, d.tp.Name, spec.side_keyword, d.depth - mtl_block.Thickness
                ))
                local mismatches = CheckToolParams(d.tool, spec)
                for _, m in ipairs(mismatches) do
                    r:Line(string.format("     %s '%s' %s", spec.label, d.tp.Name, m), "error")
                end
            else
                r:Line(string.format(
                    "  Identified %s as '%s' but could not get its ID string (GetToolpathIdString failed) - it will still be flagged below",
                    spec.label, d.tp.Name
                ), "error")
            end
        elseif #candidates == 0 then
            r:Line(string.format(
                "  Could not identify the %s (expected %s side, ~%.3f\" overcut) - any matching through-cut below will be flagged",
                spec.label, spec.side_keyword, spec.overcut_expected
            ), "error")
        else
            r:Line(string.format(
                "  %d toolpaths matched the %s criteria (%s side, ~%.3f\" overcut) - can't uniquely identify, review manually:",
                #candidates, spec.label, spec.side_keyword, spec.overcut_expected
            ), "error")
            for _, d in ipairs(candidates) do
                r:Line(string.format("     '%s' overcut=%.3f", d.tp.Name, d.depth - mtl_block.Thickness))
            end
        end
    end

    -- Identify each entry in NON_THROUGH_CUT_SPECS by side + a
    -- specific absolute cut depth. These toolpaths should NOT cut
    -- through material at all - the second pass below already flags
    -- that separately (they're not in exempted_ids), so this block
    -- only needs to validate rpm/feed/plunge/tool_dia once identified.
    for _, spec in ipairs(NON_THROUGH_CUT_SPECS) do
        local candidates = {}
        for _, d in ipairs(tp_data) do
            if d.depth and string.find(string.lower(d.side_name), spec.side_keyword, 1, true) then
                if math.abs(d.depth - spec.depth_expected) <= spec.depth_tolerance then
                    table.insert(candidates, d)
                end
            end
        end

        if #candidates == 1 then
            local d = candidates[1]
            if d.id_str then
                recognized_ids[d.id_str] = spec.label
            end
            r:Line(string.format(
                "  Identified %s: '%s' (%s side, depth=%.4f)",
                spec.label, d.tp.Name, spec.side_keyword, d.depth
            ))
            local mismatches = CheckToolParams(d.tool, spec)
            for _, m in ipairs(mismatches) do
                r:Line(string.format("     %s '%s' %s", spec.label, d.tp.Name, m), "error")
            end
        elseif #candidates == 0 then
            r:Line(string.format(
                "  Could not identify the %s (expected %s side, depth~%.4f\") - its RPM/feed/plunge/tool couldn't be checked",
                spec.label, spec.side_keyword, spec.depth_expected
            ), "error")
        else
            r:Line(string.format(
                "  %d toolpaths matched the %s criteria (%s side, depth~%.4f\") - can't uniquely identify, review manually:",
                #candidates, spec.label, spec.side_keyword, spec.depth_expected
            ), "error")
            for _, d in ipairs(candidates) do
                r:Line(string.format("     '%s' depth=%.4f", d.tp.Name, d.depth))
            end
        end
    end

    -- Second pass: build the per-toolpath report, using exempted_ids/
    -- recognized_ids above (by id_str, NOT by comparing tp objects
    -- directly - see NOTE above) to decide what to flag.
    for _, d in ipairs(tp_data) do
        local tool = d.tool
        local tool_desc = "no tool assigned"
        if tool then
            tool_desc = string.format(
                "tool='%s' dia=%.3f #%d feed=%.1f plunge=%.1f rpm=%.0f",
                tool.Name, tool.ToolDia, tool.ToolNumber,
                tool.FeedRate, tool.PlungeRate, tool.SpindleSpeed
            )
        end

        r:Line(string.format("  %-20s %s", d.tp.Name, tool_desc))

        if d.depth and d.depth > mtl_block.Thickness + 0.001 then
            local exempt_label = d.id_str and exempted_ids[d.id_str]
            if exempt_label then
                r:Line(string.format(
                    "     (cuts through material, expected - %s: depth=%.3f thickness=%.3f)",
                    exempt_label, d.depth, mtl_block.Thickness
                ))
            else
                r:Line(string.format(
                    "     CUTS THROUGH MATERIAL: toolpath='%s' side='%s' depth=%.3f thickness=%.3f",
                    d.tp.Name, d.side_name, d.depth, mtl_block.Thickness
                ), "error")
            end
        else
            -- Doesn't cut through - if it also wasn't matched by any
            -- spec in NON_THROUGH_CUT_SPECS, it's not one of the 7
            -- expected operations - e.g. an extra toolpath the student
            -- added (an engraved name, initials, etc.) that you should
            -- know about even if you've already approved it.
            local recognized_label = d.id_str and recognized_ids[d.id_str]
            if not recognized_label then
                r:Line(string.format(
                    "     UNRECOGNIZED TOOLPATH: '%s' side='%s' - doesn't match any of the 7 expected operations, review manually",
                    d.tp.Name, d.side_name
                ), "error")
            end
        end
    end

    return r
end

function main(script_path)
    local job = VectricJob()
    if not job.Exists then
        local dialog = HTML_Dialog(false, "file:" .. script_path .. "\\" .. g_html_file, g_width, g_height, g_title)
        dialog:AddLabelField("ReportText", "No job loaded - open the student's file first.")
        dialog:ShowDialog()
        return false
    end

    local mtl_block = MaterialBlock()
    local units = mtl_block.InMM and "mm" or "inches"

    -- The FULL report: everything, in order, informational and
    -- flagged alike. Built once here and reused for both the verbose
    -- view and (filtered by severity) the compact summary below.
    local full = NewReport()
    full:Line("CRIBBAGE BOARD REVIEW REPORT v" .. g_version)
    full:Line("========================================")
    full:Line("Job: " .. job.Name)
    full:Line("Units: " .. units)
    full:Blank()
    full:Line("MATERIAL")
    full:Line("----------------------------------------")
    full:Line(string.format(
        "  Width=%.3f  Height=%.3f  Thickness=%.3f %s",
        mtl_block.Width, mtl_block.Height, mtl_block.Thickness, units
    ))
    full:Blank()

    full:Append(FormatMaterialSetupReport(mtl_block))
    full:Append(FormatJobTypeReport(job))
    full:Append(FormatDowelHoleSymmetryReport(job))

    -- Web width / lead-in-out / centering checks - depend on both the
    -- workpiece vector geometry and the identified cutout toolpath, so
    -- they're assembled here rather than inside a single Format*Report
    -- function.
    do
        local section = NewReport()
        section:Blank()
        section:Header("WEB WIDTH / LEAD-IN-OUT CHECKS")

        local workpiece_box = FindWorkpieceBoundingBox(job)
        if workpiece_box == nil then
            section:Line("  Could not find workpiece (no closed contours found) - web/lead checks skipped", "error")
        else
            local stock_box = mtl_block.MaterialBox
            section:Append(FormatWorkpieceCenteringReport(workpiece_box, stock_box))

            local cutout_tp, cutout_err = FindCutoutToolpathForLeadCheck(job, mtl_block)
            if cutout_tp == nil then
                section:Line("  " .. cutout_err .. " - web/lead checks skipped", "error")
            else
                local bit_dia = nil
                local ok_tool, tool = pcall(function() return cutout_tp.Tool end)
                if ok_tool and tool ~= nil then
                    bit_dia = ConvertUnitsFrom(tool.ToolDia, tool, mtl_block)
                end

                section:Append(FormatWebWidthReport(workpiece_box, stock_box, bit_dia))
                section:Append(FormatLeadEncroachmentReport(cutout_tp, workpiece_box, stock_box, bit_dia))
            end
        end
        full:Append(section)
    end

    full:Blank()
    full:Append(FormatLayerReport(job))
    full:Append(FormatToolpathReport(job, mtl_block))

    if full.flagged then
        full:Blank()
        full:Line("*** ISSUES FLAGGED ABOVE - REVIEW BEFORE APPOINTMENT ***")
    end

    -- NOTE: job:CopyToClipboard() is NOT used here. It reported success
    -- (returned true) in testing on 2026-08-08, but the text never
    -- actually reached the Windows clipboard (verified via Win+V
    -- clipboard history AND a direct Ctrl+V paste test, both empty/
    -- unchanged). Root cause undetermined.
    --
    -- Also tried writing the full report to a text file via io.open(),
    -- but VCarve's Lua environment rejects write mode ("bad argument #2
    -- to 'open' (invalid mode)") - Gadgets appear to be sandboxed against
    -- filesystem writes, which is a reasonable security posture given
    -- Gadgets can be shared/installed from untrusted sources.
    --
    -- So: an HTML dialog (see REPORT ARCHITECTURE note at the top of
    -- this file) is the only output. It's scrollable (though not
    -- resizable), and stays compact by default, showing only the
    -- WARNINGS/ERRORS bullets rather than the full report - the full
    -- detail for anything flagged is still visible by scrolling the
    -- actual job in VCarve, or by setting VERBOSE_OUTPUT = true.

    local summary = NewReport()
    summary:Line("CRIBBAGE BOARD REVIEW SUMMARY v" .. g_version)
    summary:Line("Job: " .. job.Name)
    summary:Line(string.format(
        "Material: %.3f x %.3f x %.3f %s",
        mtl_block.Width, mtl_block.Height, mtl_block.Thickness, units
    ))
    summary:Line(string.format(
        "Layers: %d   Toolpaths: %d",
        job.LayerManager.Count, ToolpathManager().Count
    ))

    -- Intro block never contains flagged lines, so it's always safe to
    -- render as-is via RecordsToHtml.
    local report_html = RecordsToHtml(summary.records)

    if VERBOSE_OUTPUT then
        -- Full report - everything, passing and flagged alike, colored
        -- by each record's real severity field (see REPORT ARCHITECTURE
        -- at the top of this file) rather than by searching the text
        -- for a marker substring.
        report_html = report_html .. "<br>\n" .. RecordsToHtml(full.records)
    elseif full.flagged then
        -- Compact summary: WARNINGS/ERRORS as plain bullet lists with
        -- NO severity-marker text anywhere in the displayed/copied
        -- content - see BulletSectionHtml and the REPORT ARCHITECTURE
        -- note at the top of this file.
        local warning_records = {}
        local error_records = {}
        for _, rec in ipairs(full.records) do
            if rec.severity == "warning" then
                table.insert(warning_records, rec)
            elseif rec.severity == "error" then
                table.insert(error_records, rec)
            end
        end

        if #warning_records > 0 then
            report_html = report_html .. BulletSectionHtml("WARNINGS:", warning_records, "#b35900")
        end
        if #error_records > 0 then
            report_html = report_html .. BulletSectionHtml("ERRORS:", error_records, "#b00000")
        end
    else
        report_html = report_html .. "<br>\nNo issues flagged."
    end

    local html_path = "file:" .. script_path .. "\\" .. g_html_file
    local dialog_title = g_title .. "  \226\128\148  " .. job.Name
    local dialog = HTML_Dialog(false, html_path, g_width, g_height, dialog_title)
    dialog:AddLabelField("ReportText", report_html)
    dialog:ShowDialog()

    return true
end
