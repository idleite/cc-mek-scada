local log        = require("scada-common.log")
local util       = require("scada-common.util")

local docs       = require("pocket.ui.docs")

local core       = require("graphics.core")

local Div        = require("graphics.elements.div")
local ListBox    = require("graphics.elements.listbox")
local TextBox    = require("graphics.elements.textbox")

local PushButton = require("graphics.elements.controls.push_button")

local IndicatorLight = require("graphics.elements.indicators.light")
local LED        = require("graphics.elements.indicators.led")

local ALIGN = core.ALIGN
local cpair = core.cpair

local LIST_TYPE = docs.DOC_LIST_TYPE

-- new guide documentation section
---@param data _guide_section_constructor_data
---@param base_page nav_tree_page
---@param title string
---@param items table
---@param scroll_height integer
---@return nav_tree_page
return function (data, base_page, title, items, scroll_height)
    local app, page_div, panes, doc_map, search_db, btn_fg_bg, btn_active = table.unpack(data)

    local section_page = app.new_page(base_page, #panes + 1)
    local section_div = Div{parent=page_div,x=2}
    table.insert(panes, section_div)
    TextBox{parent=section_div,y=1,text=title,alignment=ALIGN.CENTER}
    PushButton{parent=section_div,x=3,y=1,text="<",fg_bg=btn_fg_bg,active_fg_bg=btn_active,callback=base_page.nav_to}

    local view_page = app.new_page(section_page, #panes + 1)
    local section_view_div = Div{parent=page_div,x=2}
    table.insert(panes, section_view_div)
    TextBox{parent=section_view_div,y=1,text=title,alignment=ALIGN.CENTER}
    PushButton{parent=section_view_div,x=3,y=1,text="<",fg_bg=btn_fg_bg,active_fg_bg=btn_active,callback=section_page.nav_to}

    local name_list = ListBox{parent=section_div,x=1,y=3,scroll_height=30,nav_fg_bg=cpair(colors.lightGray,colors.gray),nav_active=cpair(colors.white,colors.gray)}
    local def_list = ListBox{parent=section_view_div,x=1,y=3,scroll_height=scroll_height,nav_fg_bg=cpair(colors.lightGray,colors.gray),nav_active=cpair(colors.white,colors.gray)}

    local _end

    for i = 1, #items do
        local item = items[i] ---@type pocket_doc_item|pocket_doc_list

        if item.type == nil then
            ---@cast item pocket_doc_item

            local anchor = TextBox{parent=def_list,text=item.name,anchor=true,fg_bg=cpair(colors.blue,colors.black)}
            TextBox{parent=def_list,text=item.desc}
            _end = Div{parent=def_list,height=1,can_focus=true}

            local function view()
                _end.focus()
                view_page.nav_to()
                anchor.focus()
            end

            doc_map[item.key] = view
            table.insert(search_db, { string.lower(item.name), item.name, title, view })

            PushButton{parent=name_list,text=item.name,fg_bg=cpair(colors.blue,colors.black),active_fg_bg=btn_active,callback=view}

            if i % 12 == 0 then util.nop() end
        else
            ---@cast item pocket_doc_list

            if item.type == LIST_TYPE.BULLET then
                for _, li in ipairs(item.items) do
                    TextBox{parent=def_list,x=2,text="\x07 "..li}
                end
            elseif item.type == LIST_TYPE.NUMBERED then
                local width = string.len("" .. #item.items)
                for idx, li in ipairs(item.items) do
                    TextBox{parent=def_list,x=2,text=util.sprintf("%" .. width .. "d. %s", idx, li)}
                end
            elseif item.type == LIST_TYPE.INDICATOR then
                for idx, li in ipairs(item.items) do
                    local _ = IndicatorLight{parent=def_list,x=2,label=li,colors=cpair(colors.black,item.colors[idx])}
                end
            elseif item.type == LIST_TYPE.LED then
                for idx, li in ipairs(item.items) do
                    local _ = LED{parent=def_list,x=2,label=li,colors=cpair(colors.black,item.colors[idx])}
                end
            end

            local _ = Div{parent=def_list,height=1}
        end
    end

    log.debug("guide section " .. title .. " generated with final height ".. _end.get_y())

    util.nop()

    return section_page
end
