local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("YahtzeeAI", function()
    local Board, AI

    setup(function()
        Board = require("board")
        AI    = require("ai")
    end)

    local function with_dice(dice, rolls_left, scores)
        local b = Board:new()
        b.dice, b.rolls_left = dice, rolls_left
        b.held = { false, false, false, false, false }
        for k, v in pairs(scores or {}) do b.players[1].scores[k] = v end
        return b
    end

    it("stands pat on a Yahtzee", function()
        local b = with_dice({ 6, 6, 6, 6, 6 }, 2)
        local held, reroll = AI.chooseHolds(b)
        assert.is_false(reroll)
        assert.are.same({ true, true, true, true, true }, held)
        assert.are.equal("yahtzee", AI.chooseCategory(b))
    end)

    it("stands pat on a large straight", function()
        local b = with_dice({ 2, 3, 4, 5, 6 }, 2)
        local _, reroll = AI.chooseHolds(b)
        assert.is_false(reroll)
        assert.are.equal("large_straight", AI.chooseCategory(b))
    end)

    it("keeps the four of a kind and rerolls the odd die", function()
        local b = with_dice({ 5, 5, 2, 5, 5 }, 2)
        local held, reroll = AI.chooseHolds(b)
        assert.is_true(reroll)
        assert.are.same({ true, true, false, true, true }, held)
    end)

    it("only ever picks a legal box", function()
        math.randomseed(11)
        for _ = 1, 3 do
            local b = Board:new{ players = { { ai = true }, { ai = true } } }
            while not b.game_over do
                b:roll()
                while b.rolls_left > 0 do
                    local held, reroll = AI.chooseHolds(b)
                    if not reroll then break end
                    b:setHolds(held)
                    b:roll()
                end
                local cat = AI.chooseCategory(b)
                assert.is_not_nil(b:scoreFor(cat))
                assert.is_not_nil(b:score(cat))
            end
        end
    end)

    it("averages well above a random scorer", function()
        math.randomseed(2026)
        local total, n = 0, 20
        for _ = 1, n do
            local b = Board:new{ players = { { ai = true } } }
            while not b.game_over do AI.playTurn(b) end
            total = total + Board.total(b.players[1])
        end
        -- Measured over 1000 games: ~240 (see README). 20 games keep the
        -- spec fast; 190 leaves a wide margin for their spread.
        assert.is_true(total / n > 190)
    end)
end)
