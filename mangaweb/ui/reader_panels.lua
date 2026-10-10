local Controls={}
Controls.__index=Controls
local Preferences=require('mangaweb.panel_settings')
local copy=require('mangaweb.filter_presets').copy
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
function Controls:_save(changes,as_default,section,draft)
    local reader=self.reader
    local undo
    local function commit()
        local saved,reason,rollback=self.settings:save(reader.context.site_id,reader.context.comic_id,changes,as_default)
        undo=rollback;return saved,reason
    end
    local function rollback() if undo then undo() end end
    local ok,saved,reason=pcall(function()
        if reader.panels and changes.enabled~=false then
            return reader.panels:configure(changes,commit,rollback)
        end
        return commit()
    end)
    if ok and saved and changes.enabled==false then reader:exit_panel_mode() end
    if ok and saved then
        return self:show(nil,as_default and '已保存本漫画，并设为新漫画默认。' or '已保存本漫画。')
    end
    return self:show(section,reason=='panel_detection_failed'
        and '当前页无法安全分格，已返回整页；原设置保留。'
        or '保存或预览失败，原设置保留，请重试。',draft)
end
function Controls:show(section,status,draft)
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
    local rows,title
    local tuning={strength_percent=current.strength_percent,min_area_permille=current.min_area_permille,
        frame_min=current.frame_min,dialogue_distance_percent=current.dialogue_distance_percent}
    if draft then tuning=copy(draft) end
    local function action(text,callback,hold)
        return {text=text,callback=guard(callback),hold_callback=hold and guard(hold) or nil}
    end
    local function change(key,value)
        local next_draft=copy(tuning);next_draft[key]=value
        return self:show(section,nil,next_draft)
    end
    local function adjust(key,delta,minimum,maximum)
        return change(key,math.max(minimum,math.min(maximum,tuning[key]+delta)))
    end
    if section=='strength' then
        title='识别强度'
        rows={
            {kind='info',text=('识别强度：%d%%（50%%～200%%）'):format(tuning.strength_percent)},
            {kind='info',text='100%沿用原来的识别效果；提高比例会更容易识别浅色线条，不代表一定分出更多格。'},
            row(action('−10%',function() return adjust('strength_percent',-10,50,200) end),
                action('＋10%',function() return adjust('strength_percent',10,50,200) end)),
            row(action('默认100%',function() return change('strength_percent',100) end)),
        }
    elseif section=='advanced' then
        title='高级识别设置'
        rows={
            {kind='info',text=('小格过滤：最小面积 %g%%（默认0.2%%）'):format(tuning.min_area_permille/10)},
            row(action('0.1%',function() return change('min_area_permille',1) end),
                action('0.2%',function() return change('min_area_permille',2) end),
                action('0.5%',function() return change('min_area_permille',5) end)),
            row(action('1%',function() return change('min_area_permille',10) end),
                action('2%',function() return change('min_area_permille',20) end)),
            {kind='info',text=('边框严格度：%d条有效边（默认1条）'):format(tuning.frame_min)},
            row(action('1条',function() return change('frame_min',1) end),
                action('2条',function() return change('frame_min',2) end),
                action('3条',function() return change('frame_min',3) end),
                action('4条',function() return change('frame_min',4) end)),
            {kind='info',text=('溢出对白保护范围：%d%%（5%%～25%%，默认12%%）'):format(tuning.dialogue_distance_percent)},
            row(action('−1%',function() return adjust('dialogue_distance_percent',-1,5,25) end),
                action('＋1%',function() return adjust('dialogue_distance_percent',1,5,25) end)),
            row(action('−5%',function() return adjust('dialogue_distance_percent',-5,5,25) end),
                action('＋5%',function() return adjust('dialogue_distance_percent',5,5,25) end)),
            {kind='info',text='溢出对白始终保护；归属模糊时相邻两格都保留，无法安全识别时返回整页。提高过滤面积或边框严格度可能使当前页不适合分格。'},
            row(action('恢复识别默认',function() return self:show(section,nil,Preferences.detection_defaults()) end)),
        }
    else
        title='智能分格'
        rows={
        {kind='info',text='点按保存本漫画；长按选项同时设为新漫画默认。开启后长按整页进入分格。'},
        row(option('智能分格：'..(current.enabled and '开启' or '关闭'),'enabled',not current.enabled)),
        row(action(('识别强度：%d%%'):format(current.strength_percent),function() return self:show('strength') end)),
        row(action('高级识别设置',function() return self:show('advanced') end)),
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
    end
    if section=='strength' or section=='advanced' then
        rows[#rows+1]=row(action('保存',function() return self:_save(tuning,false,section,tuning) end,
            function() return self:_save(tuning,true,section,tuning) end))
        rows[#rows+1]={kind='info',text='点击保存本漫画；长按保存同时设为新漫画默认。返回放弃草稿。分格中保存会利用本地原图重新识别并从首格开始；未进入分格时，下次进入生效。'}
    end
    local back=guard(function()
        if section=='strength' or section=='advanced' then return self:show() end
        return self.adapter:_show_reader_controls('root')
    end)
    local close=guard(function() return self.adapter:_close_reader_controls() end)
    model={title=title,modal=true,rows=rows,status=status,
        navigation={{text='← 返回设置',callback=back},{text='返回阅读',callback=close}},on_back=back,on_close=close}
    local ok,shown=pcall(self.adapter._show_reader_panel,self.adapter,model)
    if not ok or not shown then return false end
    panel=self.adapter.reader_controls
    return true
end
return Controls
