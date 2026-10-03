local ButtonStyle = require("mangaweb.ui.button_style")
local Preview = {}
function Preview.show(adapter,model)
    if not adapter.input_container or not adapter.image_widget or not adapter.title_bar then return nil end
    local View=adapter.input_container:extend{modal=true,fullscreen=true,covers_fullscreen=true,stop_events_propagation=true}
    local Button=ButtonStyle.extend(adapter.button,adapter.screen,adapter.blitbuffer)
    function View:init()
        self.dimen=adapter.screen:getSize()
        local groups=adapter.device and adapter.device.input and adapter.device.input.group or {}
        if next(groups) then self.key_events={Back={{groups.Back or {"Back"}}}} end
        self.current="after";self.status="正在生成当前页预览…"
        self:_rebuild()
    end
    function View:_clear_body()
        local child=self[1]
        self[1],self.image=nil,nil
        if child and child.free then pcall(child.free,child) end
    end
    function View:_rebuild()
        if self.closed then return end
        self:_clear_body()
        local title=adapter.title_bar:new{title=model.title,width=self.dimen.w,
            right_icon="close",right_icon_allow_flash=false,
            right_icon_tap_callback=function()return self:close()end}
        local footer=adapter.horizontal_group:new{}
        for _,value in ipairs({{"before","调整前"},{"after","调整后"},{"close","返回"}})do
            local id,label=value[1],value[2]
            footer[#footer+1]=Button:new{text=id==self.current and "["..label.."]" or label,
                width=math.floor(self.dimen.w/3),callback=function()
                    return id=="close" and self:close() or self:select(id)
                end}
        end
        local height=math.max(1,self.dimen.h-title:getSize().h-footer:getSize().h)
        local path=self.current=="before" and self.before_path or self.after_path
        local body
        if path then
            local image
            local created=pcall(function()
                image=adapter.image_widget:new{file=path,image_disposable=true,file_do_cache=false,
                    width=self.dimen.w,height=height,scale_factor=0}
                image:getSize()
                if image._is_straight_alpha==false then error("image_decode_failed") end
            end)
            if created then self.image=image;body=image
            else
                if image and image.free then pcall(image.free,image) end
                self.status="预览显示失败，原图未修改；请返回重试"
            end
        end
        if not body then
            body=adapter.text_widget:new{text=self.status,face=adapter.font:getFace("cfont",18)}
        end
        self[1]=adapter.frame_container:new{margin=0,padding=0,bordersize=0,
            background=adapter.blitbuffer.COLOR_WHITE,
            adapter.vertical_group:new{title,adapter.center_container:new{
                dimen=adapter.geom:new{w=self.dimen.w,h=height},body},footer}}
        adapter.ui_manager:setDirty(self,"ui")
    end
    function View:set_paths(before,after)
        if self.closed then return false end
        self.before_path,self.after_path=before,after
        self:_rebuild();return true
    end
    function View:set_error(message)
        if self.closed then return false end
        self.before_path,self.after_path=nil,nil
        self.status=message;self:_rebuild();return true
    end
    function View:paintTo(bb,x,y)
        if self.closed then return end
        local painted=pcall(adapter.input_container.paintTo,self,bb,x,y)
        if painted or self.paint_failed then return end
        self.paint_failed=true
        local function recover()
            if not self.closed then self:set_error("预览显示失败，原图未修改；请返回重试") end
        end
        if adapter.ui_manager.nextTick then adapter.ui_manager:nextTick(recover)
        elseif adapter.ui_manager.scheduleIn then adapter.ui_manager:scheduleIn(0,recover) end
    end
    function View:select(which)
        if self.closed or (which~="before" and which~="after") then return false end
        self.current=which;self:_rebuild();return true
    end
    function View:close()
        if self.closed then return true end
        self.closed=true
        adapter.ui_manager:close(self)
        self:onCloseWidget()
        return true
    end
    function View:onCloseWidget()
        if self.released then return end
        self.closed,self.released=true,true
        self:_clear_body()
        if model.on_close then pcall(model.on_close) end
    end
    function View:onBack()return self:close()end
    local created,view=pcall(View.new,View,{})
    if not created then return nil end
    local shown=pcall(adapter.ui_manager.show,adapter.ui_manager,view)
    if not shown then view:onCloseWidget();return nil end
    return view
end
return Preview
