local Ui={};Ui.__index=Ui
local MB=1048576
local REASONS={below_upper='未超过上限，无需清理',cleaned='已按规则清理',
    protected_limit='使用中或收藏保护的文件较多，暂未达到下限',cleanup_failed='部分文件清理失败，请稍后重试',
    scan_failed='缓存目录读取失败',scheduler_unavailable='检查暂未完成，请返回重试'}
function Ui:new(options)
    return setmetatable({manager=assert(options.manager),shell=assert(options.shell),view_token=options.view_token},self)
end
function Ui:active()
    return not self.shell.closed and (not self.shell.is_view or self.shell:is_view(self.view_token))
end
function Ui:show(stats,status)
    if not self:active() then return false end
    stats=stats or self.manager:stats()
    local summary={}
    for _,key in ipairs{'total_bytes','protected_bytes','pages_bytes','covers_bytes','catalogues_bytes',
        'last_checked','reason','freed_bytes','scan_failed'}do summary[key]=stats[key] end
    return self.shell:set_model({page='global_cache',state='ready',stats=summary,
        policy=self.manager:policy(),busy=self.busy,status_text=status,actions={
            back=function()return self.shell:show('site_center')end,
            save=function(policy)
                if not self:active() then return false end
                local saved,reason=self.manager:configure(policy)
                if saved then self:show() end
                return saved,reason
            end,
            check=function()
                if not self:active() or self.busy then return false end
                self.busy=true;self:show(nil,'正在检查缓存…')
                local ok=self.manager:check(true,function(result)
                    self.busy=false;if self:active()then self:show(result)end
                end)
                if not ok and self.busy then self.busy=false;self:show(nil,'检查未完成，请重试')end
                return ok
            end,
        }},self.view_token)
end
local function info(text) return {kind='info',text=text} end
function Ui.panel(model,adapter)
    local stats,policy,actions=model.stats or {},model.policy or {},model.actions or {}
    local panel={title='插件缓存管理',page='global_cache',rows={
        info(('总占用：%.2f MB；受保护：%.2f MB'):format((stats.total_bytes or 0)/MB,(stats.protected_bytes or 0)/MB)),
        info(('正文：%.2f MB；封面：%.2f MB；列表：%.2f MB'):format((stats.pages_bytes or 0)/MB,
            (stats.covers_bytes or 0)/MB,(stats.catalogues_bytes or 0)/MB)),
        info(('上限：%d MB；下限：%d MB；每 %d 分钟检查'):format(policy.upper_mb or 256,policy.lower_mb or 192,policy.interval_minutes or 10)),
        info('超过上限时，按最久未使用顺序清理到下限。\n使用中、预加载的图片和收藏封面会保留。'),
    },on_back=actions.back,on_close=actions.back}
    if stats.last_checked then panel.rows[#panel.rows+1]=info('上次检查：'..os.date('%m-%d %H:%M',stats.last_checked))end
    panel.status=model.status_text or (stats.scan_failed and REASONS.scan_failed)
        or REASONS[stats.reason] or '自动检查仅在插件打开期间运行'
    if stats.freed_bytes then panel.status=panel.status..('；本次释放 %.2f MB'):format(stats.freed_bytes/MB)end
    panel.actions={
        {text='修改容量与检查间隔',enabled=not model.busy,callback=function()return Ui.edit(adapter,policy,actions.save)end},
        {text='立即检查并按规则清理',enabled=not model.busy,callback=actions.check},
        {text='返回我的',callback=actions.back},
    }
    return panel
end
function Ui.edit(adapter,policy,save)
    local Dialog=adapter.multi_input_dialog
    if not Dialog or not adapter.ui_manager then return false end
    local dialog
    local function warning()
        local message='保存失败。请检查：64–32768 MB 上限，0 ≤ 下限 < 上限，检查间隔 1–1440 分钟。'
        adapter.cache_notice=message
        local ok,Info=pcall(require,'ui/widget/infomessage')
        if ok then adapter.ui_manager:show(Info:new{text=message,timeout=4,modal=true})end
    end
    dialog=Dialog:new(adapter:_input_dialog_options({title='插件缓存策略',fields={
        {description='缓存上限（MB）',text=tostring(policy.upper_mb),input_type='number'},
        {description='清理下限（MB）',text=tostring(policy.lower_mb),input_type='number'},
        {description='检查间隔（分钟）',text=tostring(policy.interval_minutes),input_type='number'},
    },buttons={{
        {text='取消',id='close',callback=function()return adapter:_close_input_dialog(dialog)end},
        {text='保存',callback=function()
            if adapter.input_dialog~=dialog then return true end
            local fields=dialog:getFields()or {}
            local ok,result=pcall(save,{upper_mb=tonumber(fields[1]),lower_mb=tonumber(fields[2]),interval_minutes=tonumber(fields[3])})
            if ok and result==true then adapter:_close_input_dialog(dialog) else warning()end
            return true
        end},
    }}},function()return dialog end))
    return adapter:_show_input_dialog(dialog)
end
function Ui.reader(adapter,reader,manager)
    local page,session=adapter.reader_widget,reader.loader_generation
    local function active()return not reader.closed and adapter.reader==reader
        and adapter.reader_widget==page and reader.loader_generation==session end
    local show
    show=function(stats,status)
        if not active() then return false end
        local model={policy=manager:policy(),stats=stats or manager:stats(),status_text=status,actions={
            save=function(policy)
                if not active() then return false end
                local ok,reason=manager:configure(policy)
                if ok then
                    if reader.reload_cache_policy then reader:reload_cache_policy()end
                    show()
                end
                return ok,reason
            end,
            check=function()
                if not active()then return false end
                return manager:check(true,function(result)if active()then show(result)end end)
            end,
        }}
        local panel=Ui.panel(model,adapter)
        panel.modal=true
        panel.actions[3]=nil
        panel.navigation={{text='← 返回设置',callback=function()if active()then return adapter:_show_reader_controls('root')end end},
            {text='返回阅读',callback=function()return adapter:_close_reader_controls()end}}
        panel.on_back=panel.navigation[1].callback;panel.on_close=panel.navigation[2].callback
        return adapter:_show_reader_panel(panel)
    end
    return show()
end
return Ui
