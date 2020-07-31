local Chara = require("api.Chara")
local Draw = require("api.Draw")
local Gui = require("api.Gui")
local IInput = require("api.gui.IInput")
local IUiLayer = require("api.gui.IUiLayer")
local Input = require("api.Input")
local InputHandler = require("api.gui.InputHandler")
local Log = require("api.Log")
local Ui = require("api.Ui")
local UiList = require("api.gui.UiList")
local UiTheme = require("api.gui.UiTheme")
local UiWindow = require("api.gui.UiWindow")
local Pixma = require("mod.pixma.api.Pixma")
local vips = require("vips")

local PrintDialog = class.class("PrintDialog", IUiLayer)

PrintDialog:delegate("input", IInput)
PrintDialog:delegate("list", "items")

function PrintDialog:init(ip)
   ip = ip or config["pixma.printer_ip"]

   self.pixma = Pixma:new(ip)
   self.status = {}
   self.paper_size = "custom_canon_127x127mm"

   self.win = UiWindow:new("Printer Status", true)
   self.list = UiList:new {
      "Select Item",
      "Select Paper",
      "Print",
   }

   self.input = InputHandler:new()
   self.input:forward_to(self.list)
   self.input:bind_keys(self:make_keymap())
   self.image = nil
end

function PrintDialog:make_keymap()
   return {
      escape = function() self.canceled = true end,
      cancel = function() self.canceled = true end
   }
end

function PrintDialog:on_query()
   Gui.play_sound("base.pop2")
   local ok, status = pcall(Pixma.get_status, self.pixma)
   if not ok then
      Gui.mes("It looks like the printer isn't responding... " .. status)
      return false
   end
   self.status = status
end

function PrintDialog:make_chip_batch()
   local batch = Draw.make_chip_batch("chip")

   if self.image then
      batch:add(self.image, 0, 0, 48, 48)
   end

   return batch
end

function PrintDialog:relayout(x, y)
   self.width = 500
   self.height = 350
   self.x, self.y = Ui.params_centered(self.width, self.height)

   self.t = UiTheme.load(self)
   self.chip_batch = self:make_chip_batch()

   self.win:relayout(self.x, self.y, self.width, self.height)
   self.list:relayout(self.x + math.floor(self.width / 2) - 80, self.y + math.floor((self.height / 4) * 2.6))
end

local COLORS = {
   C = { 0, 255, 255 },
   BK = { 0, 0, 0 },
   PB = { 128, 0, 128 },
   Y = { 255, 255, 0 },
   PGBK = { 0, 0, 0 },
   M = { 192, 0, 255 },
}

local PAPER_SIZES = {
   { "custom_canon_127x127mm", "5 x 5\"" },
   { "na_index-4x6_4x6in", "4 x 6\"" },
}
local PAPER_NAMES = {}
for _, v in ipairs(PAPER_SIZES) do
   PAPER_NAMES[v[1]] = v[2]
end

function PrintDialog:draw()
   Draw.set_color(255, 255, 255)

   self.win:draw()
   self.list:draw()

   Draw.set_font(14)

   if self.status.marker_info then
      for i, marker in ipairs(self.status.marker_info) do
         local x = self.x + i * 60 + 15
         local y = self.y + 60
         Draw.set_color(COLORS[marker.color])
         local h = (tonumber(marker.level) / 100.0) * 100
         Draw.filled_rect(x, y + 100 - h, 20, h)
         Draw.set_color(0, 0, 0)
         Draw.line_rect(x, y, 20, 100)
         local tw = Draw.text_width(marker.color)
         Draw.text(marker.color, x - (tw / 2) + 10, y + 100 + Draw.text_height())
      end
   end

   Draw.set_color(0, 0, 0)
   Draw.text("Scanned item:", self.x + 320, self.y + 220)
   if self.image then
      self.chip_batch:draw(self.x + 350 - 12, self.y + 255 - 18)
   else
      Draw.text("None", self.x + 350, self.y + 250)
   end

   Draw.set_color(0, 0, 0)
   Draw.text("Paper size:", self.x + 50, self.y + 220)
   local name = PAPER_NAMES[self.paper_size]
   Draw.text(name, self.x + 90 - Draw.text_width(name) / 2, self.y + 250)
end

function PrintDialog:print()
   if not self.image then
      Gui.mes("You haven't scanned an item yet.")
      return
   end

   local canvas = Draw.create_canvas(48, 48)
   Draw.with_canvas(canvas,
                    function()
                       Draw.set_blend_mode("alpha")
                       Draw.set_color(255, 255, 255)
                       Draw.filled_rect(0, 0, 48, 48)
                       self.chip_batch:draw(0, 0)
                    end)
   local image_data = canvas:newImageData()
   canvas:release()

   -- The only popular image format this printer accepts is JPEG. But LÖVE
   -- removed its JPEG encoding feature in 0.10.0, so we have no choice but to
   -- use a different native library...
   --
   -- I don't know if this is sustainable, or if we even want to use native
   -- libraries in mods. Minecraft does allow them (see the Discord API
   -- integration), but the modding culture might be different there.
   local png = image_data:encode("png")
   local im = vips.Image.new_from_buffer(png:getString())
   local buffer = im:write_to_buffer(".jpg", {Q = 100})

   local opts = {
      papersize = self.paper_size
   }

   Gui.mes("Printing...")
   self.pixma:start_job(buffer, "JPEGPAGE", 2, opts)
end

function PrintDialog:update(dt)
   if self.list.chosen then
      if self.list.selected == 1 then
         local result, canceled = Input.query_item(Chara.player(), "elona.inv_examine")
         if result then
            local item = result.result
            self.image = item:calc("image")
            self.chip_batch = self:make_chip_batch()
            Gui.mes("You scan the " .. item:build_name(1, true) .. ".")
            Gui.play_sound("pixma.printer_on")
         end
      elseif self.list.selected == 2 then
         Gui.mes("Which paper?")
         local choices = fun.iter(PAPER_SIZES):extract(2):to_list()
         local result, canceled = Input.prompt(choices)
         if result then
            self.paper_size = PAPER_SIZES[result.index][1]
            Gui.play_sound("base.ok1")
         end
      elseif self.list.selected == 3 then
         Gui.play_sound("base.ok1")
         self:print()
      end
   end

   self.win:update(dt)
   self.list:update(dt)

   if self.canceled then
      self.canceled = false
      return nil, "canceled"
   end
end

return PrintDialog
