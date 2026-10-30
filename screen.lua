local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase   = require("screen_base")
local MenuHelper   = require("menu_helper")
local ScoreTracker = require("score_tracker")

local YahtzeeBoard       = lrequire("board")
local YahtzeeBoardWidget = lrequire("board_widget")
local YahtzeeAI          = lrequire("ai")

local GAME_RULES_EN = _([[
Yahtzee — Rules

Each turn, roll the five dice up to three times. After the first and second roll, tap the dice you want to keep: held dice are shown in black and stay put on the next roll. Then score the dice in one empty box of your sheet — tap the box once to see it highlighted, tap it again to confirm. The grey numbers show what each box would score. Every box must be filled once, even with a zero: after 13 rounds the highest total wins.

Upper section: Ones to Sixes score the sum of the dice showing that face. A total of 63 or more (three of each face) earns a 35-point bonus.

Lower section:
• Three of a kind / Four of a kind: at least three / four identical dice; scores the sum of all five dice.
• Full house: three of one face and two of another — 25.
• Small straight: four consecutive faces — 30.
• Large straight: five consecutive faces — 40.
• Yahtzee: five identical dice — 50.
• Chance: any dice; scores their sum.

Extra Yahtzees: once the Yahtzee box holds 50, every further Yahtzee earns a 100-point bonus. It must then go in the matching upper box if that one is empty; otherwise in any lower box, where it scores full value (25, 30 or 40 for the full house and straights); otherwise in any upper box for zero.

Players: from one to four, sharing the device, plus up to three computer players (title-bar menu). Alone, your best score is kept.
]])

local GAME_RULES_FR = [[
Yam's (Yahtzee) — Règles

À chaque tour, lancez les cinq dés jusqu'à trois fois. Après le premier et le deuxième lancer, touchez les dés à garder : ils s'affichent en noir et ne bougent pas au lancer suivant. Inscrivez ensuite les dés dans une case vide de votre feuille — touchez la case une fois pour la surligner, une seconde fois pour valider. Les nombres gris indiquent ce que rapporterait chaque case. Chaque case doit être remplie une fois, même par un zéro : après 13 tours, le plus haut total l'emporte.

Section haute : les As à Six rapportent la somme des dés montrant cette face. Un total de 63 ou plus (trois de chaque face) rapporte une prime de 35 points.

Section basse :
• Brelan / Carré : au moins trois / quatre dés identiques ; rapporte la somme des cinq dés.
• Full : trois dés d'une face et deux d'une autre — 25.
• Petite suite : quatre faces consécutives — 30.
• Grande suite : cinq faces consécutives — 40.
• Yam's : cinq dés identiques — 50.
• Chance : n'importe quels dés ; rapporte leur somme.

Yam's supplémentaires : une fois la case Yam's remplie à 50, chaque nouveau Yam's rapporte une prime de 100 points. Il doit alors aller dans la case haute correspondante si elle est vide ; sinon dans n'importe quelle case basse, où il compte plein (25, 30 ou 40 pour le full et les suites) ; sinon dans une case haute, pour zéro.

Joueurs : de un à quatre sur le même appareil, plus jusqu'à trois joueurs ordinateur (menu de la barre de titre). En solo, votre meilleur score est conservé.
]]

local AI_DELAY  = 0.9          -- seconds between the computer's visible steps
local BEST_KEY  = "best_score"

-- Sheet labels for the 13 boxes.
local CAT_LABELS = {
    ones = _("Ones"), twos = _("Twos"), threes = _("Threes"),
    fours = _("Fours"), fives = _("Fives"), sixes = _("Sixes"),
    three_kind = _("Three of a kind"), four_kind = _("Four of a kind"),
    full_house = _("Full house"), small_straight = _("Small straight"),
    large_straight = _("Large straight"), yahtzee = _("Yahtzee"),
    chance = _("Chance"),
}

local YahtzeeScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function YahtzeeScreen:init()
    self.board = YahtzeeBoard:new{ players = self:_playerSetup() }
    if not self.board:load(self.plugin:loadState()) then
        self.board:newGame(self:_playerSetup())
    end
    ScreenBase.init(self)
    self:maybeRunAI()
end

function YahtzeeScreen:serializeState()
    return self.board:serialize()
end

function YahtzeeScreen:closeScreen()
    self.closed = true
    if self._ai_step then UIManager:unschedule(self._ai_step) end
    ScreenBase.closeScreen(self)
end

function YahtzeeScreen:save()
    self.plugin:saveState(self.board:serialize())
end

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------

function YahtzeeScreen:_humans()
    return self.plugin:getSetting("players", 1)
end

function YahtzeeScreen:_computers()
    return math.min(self.plugin:getSetting("computers", 0),
                    YahtzeeBoard.MAX_PLAYERS - self:_humans())
end

-- Humans first, then the computers.
function YahtzeeScreen:_playerSetup()
    local list = {}
    for _ = 1, self:_humans() do list[#list + 1] = { ai = false } end
    for _ = 1, self:_computers() do list[#list + 1] = { ai = true } end
    return list
end

-- Full name (status line) and short name (sheet column) of player i.
function YahtzeeScreen:_playerNames(i)
    local players = self.board.players
    local p = players[i]
    local nth, of = 0, 0
    for j, q in ipairs(players) do
        if q.ai == p.ai then
            of = of + 1
            if j <= i then nth = nth + 1 end
        end
    end
    if p.ai then
        if of == 1 then return _("Computer"), _("CPU") end
        return T(_("Computer %1"), nth), T(_("CPU %1"), nth)
    end
    if of == 1 then return _("You"), _("You") end
    return T(_("Player %1"), nth), T(_("P%1"), nth)
end

function YahtzeeScreen:_shortNames()
    local out = {}
    for i = 1, #self.board.players do
        local _, short = self:_playerNames(i)
        out[i] = short
    end
    return out
end

function YahtzeeScreen:openPlayersMenu()
    local items = {}
    for n = 1, YahtzeeBoard.MAX_PLAYERS do items[n] = { id = n, text = tostring(n) } end
    MenuHelper.openPickerMenu{
        title      = _("Players"),
        items      = items,
        current_id = self:_humans(),
        on_select  = function(id)
            self.plugin:saveSetting("players", id)
            self:onNewGame()
        end,
        parent = self,
    }
end

function YahtzeeScreen:openComputersMenu()
    local items = {}
    for n = 0, YahtzeeBoard.MAX_PLAYERS - self:_humans() do
        items[#items + 1] = { id = n, text = tostring(n) }
    end
    MenuHelper.openPickerMenu{
        title      = _("Computer players"),
        items      = items,
        current_id = self:_computers(),
        on_select  = function(id)
            self.plugin:saveSetting("computers", id)
            self:onNewGame()
        end,
        parent = self,
    }
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function YahtzeeScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Yahtzee"), function()
        local items = {
            { text = _("New game"), callback = function() self:onNewGame() end },
            { text = T(_("Players: %1"), self:_humans()),
              callback = function() self:openPlayersMenu() end },
            { text = T(_("Computers: %1"), self:_computers()),
              callback = function() self:openComputersMenu() end },
        }
        local best = ScoreTracker:getBest(self.plugin, BEST_KEY)
        if best then
            items[#items + 1] = { text = T(_("Best: %1"), best), callback = function() end }
        end
        items[#items + 1] = self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR)
        return items
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self:buildActionBar({
            { text = _("Roll"), callback = function() self:onRoll() end },
        }),
    }

    local padding     = Size.padding.large
    local frame_extra = 2 * (padding + Size.border.window)
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)

    self.board_widget = YahtzeeBoardWidget:new{
        board         = self.board,
        names         = self:_shortNames(),
        labels        = CAT_LABELS,
        pending       = self.pending,
        max_width     = budget_w - frame_extra,
        max_height    = budget_h - frame_extra,
        onDieTap      = function(i) self:onDieTap(i) end,
        onCategoryTap = function(cat) self:onCategoryTap(cat) end,
    }

    local board_frame = FrameContainer:new{
        padding = padding,
        margin  = 0,
        self.board_widget,
    }

    if is_landscape then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function YahtzeeScreen:_redraw(msg)
    self.board_widget.pending = self.pending
    self.board_widget:refresh()
    self:updateStatus(msg)
    self:refreshActionBar()
end

-- ---------------------------------------------------------------------------
-- Human actions
-- ---------------------------------------------------------------------------

function YahtzeeScreen:_humanTurn()
    local board = self.board
    return not board.game_over and not board:currentPlayer().ai
end

function YahtzeeScreen:onRoll()
    local board = self.board
    if board.game_over then return end
    if not self:_humanTurn() then
        self:updateStatus(_("Wait for the computer."))
        return
    end
    if board.rolls_left <= 0 then
        self:updateStatus(_("No rolls left: pick a box to score."))
        return
    end
    board:roll()
    self.pending = nil
    self:save()
    self:_redraw()
end

function YahtzeeScreen:onDieTap(i)
    local board = self.board
    if not self:_humanTurn() then return end
    if not board:hasRolled() then
        self:updateStatus(_("Roll the dice first."))
        return
    end
    if not board:canHold() then
        self:updateStatus(_("No rolls left: pick a box to score."))
        return
    end
    board:toggleHold(i)
    self:save()
    self:_redraw()
end

-- First tap highlights the box with its score; a second tap on the same box
-- writes it. A wrong box on a shared sheet can't be taken back, and a tap on
-- e-ink lands one row off easily enough.
function YahtzeeScreen:onCategoryTap(cat)
    local board = self.board
    if not self:_humanTurn() then return end
    if not board:hasRolled() then
        self:updateStatus(_("Roll the dice first."))
        return
    end
    local pts = board:scoreFor(cat)
    if not pts then
        if board:currentPlayer().scores[cat] ~= nil then
            self:updateStatus(_("That box is already filled."))
        else
            self:updateStatus(_("Joker rule: this Yahtzee must go in another box."))
        end
        return
    end
    if self.pending ~= cat then
        self.pending = cat
        self:_redraw(T(_("%1: %2 points. Tap again to score."),
                       CAT_LABELS[cat], pts + board:bonusFor()))
        return
    end
    self.pending = nil
    self:_scoreIn(cat)
    self:maybeRunAI()
end

-- Shared by both kinds of player: write the box, then report.
function YahtzeeScreen:_scoreIn(cat)
    local board = self.board
    local name = self:_playerNames(board.current)
    local got = board:score(cat)
    self:save()
    if board.game_over then
        self:_recordBest()
        self:_redraw()
    else
        self:_redraw(T(_("%1 scored %2 in %3."), name, got, CAT_LABELS[cat]))
    end
end

-- The best score is kept for human players, whatever the table: a solo game
-- and a hotseat game score the same sheet.
function YahtzeeScreen:_recordBest()
    self.new_best = false
    for _, p in ipairs(self.board.players) do
        if not p.ai then
            local tracker = ScoreTracker:new()
            tracker:set(YahtzeeBoard.total(p))
            if tracker:updateBest(self.plugin, BEST_KEY) then self.new_best = true end
        end
    end
end

function YahtzeeScreen:isRoundOver()
    return self.board.game_over
end

function YahtzeeScreen:onNewGame()
    if self._ai_step then UIManager:unschedule(self._ai_step) end
    self._ai_step, self.ai_holds_shown, self.pending, self.new_best = nil, nil, nil, nil
    self.board = YahtzeeBoard:new{ players = self:_playerSetup() }
    self:save()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    self:maybeRunAI()
end

-- ---------------------------------------------------------------------------
-- Computer players
--
-- A computer turn is played one visible step at a time: roll, show the dice
-- it holds, roll again, then score -- each followed by a pause, so the
-- table can follow what it did.
-- ---------------------------------------------------------------------------

function YahtzeeScreen:maybeRunAI()
    local board = self.board
    if self.closed or self._ai_step or board.game_over or not board:currentPlayer().ai then
        return
    end
    self._ai_step = function()
        self._ai_step = nil
        if self.closed then return end
        self:_aiStep()
        self:maybeRunAI()
    end
    UIManager:scheduleIn(AI_DELAY, self._ai_step)
end

function YahtzeeScreen:_aiStep()
    local board = self.board
    if board.game_over or not board:currentPlayer().ai then return end
    if not board:hasRolled() or self.ai_holds_shown then
        self.ai_holds_shown = nil
        board:roll()
        self:save()
        self:_redraw()
        return
    end
    if board.rolls_left > 0 then
        local held, reroll = YahtzeeAI.chooseHolds(board)
        if reroll then
            board:setHolds(held)
            self.ai_holds_shown = true
            self:save()
            self:_redraw()
            return
        end
    end
    self:_scoreIn(YahtzeeAI.chooseCategory(board))
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function YahtzeeScreen:updateStatus(msg)
    local board = self.board
    local status = msg
    if not status then
        if board.game_over then
            local leaders, best = board:leaders()
            if #board.players == 1 then
                status = self:joinStatus(T(_("Game over! Score: %1"), best),
                    self.new_best and _("New best score!")
                    or T(_("Best: %1"), ScoreTracker:getBest(self.plugin, BEST_KEY) or best))
            elseif #leaders > 1 then
                local names = {}
                for _, i in ipairs(leaders) do names[#names + 1] = (self:_playerNames(i)) end
                status = self:joinStatus(T(_("Tie: %1"), table.concat(names, ", ")),
                                         T(_("Score: %1"), best))
            else
                status = self:joinStatus(T(_("%1 wins!"), (self:_playerNames(leaders[1]))),
                                         T(_("Score: %1"), best),
                                         self.new_best and _("New best score!") or nil)
            end
        else
            local name = self:_playerNames(board.current)
            local what
            if board:currentPlayer().ai then
                what = _("Computer playing…")
            elseif not board:hasRolled() then
                what = _("Tap Roll")
            elseif board.rolls_left > 0 then
                what = T(_("Rolls left: %1"), board.rolls_left)
            else
                what = _("Pick a box")
            end
            status = self:joinStatus(name,
                T(_("Round: %1/%2"), board.round, YahtzeeBoard.NUM_ROUNDS), what)
        end
    end
    ScreenBase.updateStatus(self, status)
end

return YahtzeeScreen
