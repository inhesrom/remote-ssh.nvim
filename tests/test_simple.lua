-- Simple test to verify framework works
local test = require("tests.init")

test.describe("Simple Test", function()
    test.it("should work with basic assertions", function()
        test.assert.equals(1 + 1, 2, "Basic math should work")
        test.assert.truthy(true, "True should be truthy")
        test.assert.falsy(false, "False should be falsy")
    end)

    test.it("should work with table assertions", function()
        local table = { 1, 2, 3 }
        test.assert.contains(table, 2, "Table should contain 2")
    end)
end)
