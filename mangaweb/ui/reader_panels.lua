local Controls={}
Controls.__index=Controls
local function row(...) return {kind='actions',items={...}} end
function Controls:new(options)
    return setmetatable({adapter=options.adapter,reader=options.reader,
        settings=options.settings or options.reader.panel_preferences,
        page=options.adapter.reader_widget,generation=options.reader.loader_generation},self)
end
function Controls:active()
    return self.adapter.reader==self.reader and not self.reader.closed
        and self.reader.loader_generation==self.generation and self.adapter.reader_widget==self.page
        and self.page and not self.page.released
end
function Controls:_save(changes,as_default)
    local reader=self.reader
    local undo
    local function commit()
        local saved,reason,rollback=self.settings:save(reader.context.site_id,reader.context.comic_id,changes,as_default)
        undo=rollback;return saved,reason
    end
    local function rollback() if undo then undo() end end
    local ok,saved=pcall(function()
        if reader.panels and changes.enabled~=false then
            return reader.panels:configure(changes,commit,rollback)
        end
        return commit()
    end)
    if ok and saved and changes.enabled==false then reader:exit_panel_mode() end
    return self:show(nil,ok and saved and (as_default and '已保存本漫画，并设为新漫画默认。' or '已保存本漫画。')
        or '保存或预览失败，原设置保留，请重试。')
end
function Controls:show(section,status)
    if not self:active() or not self.settings or not self.reader.context then return false end
    local current=self.reader:panel_settings_snapshot()
    local model,panel
    local function guard(callback)
        return function(...)
            if not self:active() or not panel or panel.closed or self.adapter.reader_controls~=panel then return true end
            local ok,result=pcall(callback,...)
            return ok and result~=false or true
        end
    end
    local function option(text,key,value)
        return {text=text,callback=guard(function() return self:_save({[key]=value},false) end),
            hold_callback=guard(function() return self:_save({[key]=value},true) end)}
    end
    local rows={
        {kind='info',text='点按保存本漫画；长按选项同时设为新漫画默认。开启后长按整页进入分格。'},
        row(option('智能分格：'..(current.enabled and '开启' or '关闭'),'enabled',not current.enabled)),
        {kind='info',text='当前视图：'..({context='保留周边',cut='独立格',free='自由视图'})[current.view]},
        row(option('保留周边','view','context'),option('独立格','view','cut'),option('自由视图','view','free')),
        {kind='info',text='旋转：'..current.rotation..'°；边距：'..current.margin_percent..'%'},
        row(option('0°','rotation',0),option('90°','rotation',90),option('180°','rotation',180),option('270°','rotation',270)),
        row(option('0%','margin_percent',0),option('2%','margin_percent',2),option('5%','margin_percent',5),option('10%','margin_percent',10)),
        row(option('显示周边：'..(current.show_adjacent and '开启' or '关闭'),'show_adjacent',not current.show_adjacent)),
        {kind='info',text='操作：'..(current.navigation=='horizontal' and '左右' or '上下')..
            '；阅读顺序：'..({follow='跟随阅读',normal='普通',manga='日漫'})[current.order]},
        row(option('左右操作','navigation','horizontal'),option('上下操作','navigation','vertical')),
        row(option('反向操作：'..(current.reverse_navigation and '开启' or '关闭'),'reverse_navigation',not current.reverse_navigation)),
        row(option('跟随阅读','order','follow'),option('普通顺序','order','normal'),option('日漫顺序','order','manga')),
        row({text='退出分格',callback=guard(function() self.reader:exit_panel_mode();return self.adapter:_close_reader_controls() end)}),
    }
    local back=guard(function() return self.adapter:_show_reader_controls('root') end)
    local close=guard(function() return self.adapter:_close_reader_controls() end)
    model={title='智能分格',modal=true,rows=rows,status=status,
        navigation={{text='← 返回设置',callback=back},{text='返回阅读',callback=close}},on_back=back,on_close=close}
    local ok,shown=pcall(self.adapter._show_reader_panel,self.adapter,model)
    if not ok or not shown then return false end
    panel=self.adapter.reader_controls
    return true
end
return Controls
