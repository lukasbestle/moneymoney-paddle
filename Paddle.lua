-- MoneyMoney extension for Paddle vendor accounts
-- https://github.com/lukasbestle/moneymoney-paddle
--
---------------------------------------------------------
--
-- MIT License
--
-- Copyright (c) 2022 Lukas Bestle
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

WebBanking({
    version = 1.02,
    url = "https://vendors.paddle.com/",
    services = { "Paddle" },
    description = string.format(MM.localizeText("Get balance and transactions for %s"), "Paddle"),
})

-- cache the connection object for future script executions
local connection
if LocalStorage.connection then
    connection = LocalStorage.connection --[[@as Connection]]
else
    connection = Connection()
    LocalStorage.connection = connection
end

-- define local variables and functions
---@type string, string
local email, password
local checkSession, groupTransactions, localizeText, login, parseAmount, parseDate, startTime, tableSum

-----------------------------------------------------------

---**Checks if this extension can request from a specified bank**
---
---@param protocol protocol Protocol of the bank gateway
---@param bankCode string Bank code or service name
---@return boolean | string # `true` or the URL to the online banking entry page if the extension supports the bank, `false` otherwise
function SupportsBank(protocol, bankCode)
    return protocol == ProtocolWebBanking and bankCode == "Paddle"
end

---**Performs the login to the backend with 2FA**
---
---If the method returns a `LoginChallenge` object on the first call,
---it is called a second time with `step=2`.
---
---@param protocol protocol Protocol of the bank gateway
---@param bankCode string Bank code or service name
---@param step integer Step `1` or `2` of the 2FA
---@param credentials string[] Username and password on `step=1`, the challenge response on `step=2`
---@param interactive boolean If MoneyMoney is running in the foreground
---@return LoginChallenge | LoginFailed | string | nil # 2FA challenge or optional error message
function InitializeSession2(protocol, bankCode, step, credentials, interactive)
    if step == 1 then
        -- if there's an existing connection, check if the session is still active
        if connection:getCookies() ~= "" and checkSession() then
            -- no login needed
            return nil
        end

        -- no active session, authenticate with email and password;
        -- also keep the credentials in variables for the second step
        email = credentials[1]
        password = credentials[2]
        return login({ email = email, password = password })
    elseif step == 2 then
        -- authenticate with the provided 2FA code
        return login({ email = email, password = password, code = credentials[1] })
    end
end

---**Returns a list of accounts that can be refreshed with this extension**
---
---@param knownAccounts Account[] List of accounts that are already known via FinTS/HBCI
---@return NewAccount[] | string # List of accounts that can be requsted with web scraping or error message
function ListAccounts(knownAccounts)
    -- request a month worth of transactions to ensure that there
    -- will be at least one even for smaller accounts;
    -- we only need the transaction for the account currency
    local startDate = os.date("%F", os.time() - 60 * 60 * 24 * 30)
    local endDate = os.date("%F")

    local response = connection:get(
        url .. "report/balance" .. "?start_date=" .. startDate .. "&end_date=" .. endDate .. "&action=view"
    )
    local html = HTML(response)

    return {
        {
            accountNumber = string.match(response, 'PaddleVars%.vendor = {"id":(%d+)'),
            currency = html:xpath("//*[@id='vendor-main']//tbody/tr[1]/td[6]"):text(),
            name = "Paddle",
            portfolio = false,
            owner = html:xpath("//*[@class='sb-header__vendor-name'][1]"):text(),
            type = AccountTypeOther,
        },
    }
end

---**Refreshes the balance and transaction of an account**
---
---@param account Account Account that is being refreshed
---@param since timestamp | nil POSIX timestamp of the oldest transaction to return or `nil` for portfolios
---@return AccountResults | string # Web scraping results or error message
function RefreshAccount(account, since)
    -- only return transactions if the mode was configured
    if not account.attributes.GroupTransactions then
        -- error message for the UI
        return localizeText(
            'The required user-defined field "GroupTransactions" was not configured, please refer to the README of the Paddle extension.',
            'Das notwendige benutzerdefinierte Feld "GroupTransactions" wurde nicht konfiguriert, bitte lese die README der Paddle-Erweiterung.'
        )
    end

    -- request the list of payouts if pending payouts are enabled
    local payoutsHtml
    if (account.attributes.PendingPayouts or "true") == "true" then
        payoutsHtml = HTML(connection:get(url .. "payouts/sent"))
    end

    -- prepare the request for the first page of the balance report
    local startDate = os.date("%F", startTime(account, since --[[@as integer]]))
    local endDate = os.date("%F")
    local url = url
        .. "report/balance?start_date="
        .. startDate
        .. "&end_date="
        .. endDate
        .. "&narrative=on&action=view"

    local balance = 0
    local html
    local pendingBalance = 0
    local transactions = {} --[=[@as NewTransaction[]]=]

    -- follow the pagination links until there is none
    repeat
        html = HTML(connection:get(url))

        -- parse the raw HTML table into a transaction array
        html:xpath("//*[@id='vendor-main']/table/tbody/tr"):each(function(_, element)
            local children = element:children()

            -- either get the positive credit amount or the
            -- negative debit amount
            local amount = parseAmount(children:get(5):text())
            if amount == 0 then
                amount = -parseAmount(children:get(4):text())
            end

            local transaction = {
                amount = amount,
                bookingDate = parseDate(children:get(10):text()),
                bookingText = children:get(2):text(),
                currency = children:get(7):text(),
                endToEndReference = children:get(1):text(),
                name = children:get(9):text() .. " " .. children:get(8):text(),
                purpose = children:get(3):text(),
            }

            -- separate booking text for refund requests
            if transaction.purpose == "Refund Request Received" then
                transaction.bookingText = "REFUND_REQUEST"
            end

            -- handle pending payouts if configured
            if transaction.bookingText == "PAYOUT" and (account.attributes.PendingPayouts or "true") == "true" then
                -- try to find a sent payout by the payout reference
                local sentPayout = payoutsHtml:xpath(
                    "//*[@id='vendor-main']//strong[text()='" .. children:get(8):text() .. "']/ancestor::pui-tr"
                )

                if sentPayout:length() >= 1 then
                    -- payout is sent, set the payment date to make the history graph work correctly
                    transaction.bookingDate = parseDate(sentPayout:children():get(2):text())
                else
                    -- payout is pending
                    transaction.booked = false

                    -- display the transaction on the current day because
                    -- the actual booking date is still in the future
                    -- (avoids a jump in the graph once the payout gets sent)
                    transaction.bookingDate = os.time()

                    -- fake the balance to account for the pending payout
                    -- (simulate that the payout is contained in the balance);
                    -- operators are swapped because the amount is negative
                    balance = balance - transaction.amount
                    pendingBalance = pendingBalance + transaction.amount
                end
            end

            table.insert(transactions, transaction)
        end)

        -- get the next URL or unset the URL if there is no next link
        local nextLink = html:xpath("//*[@id='vendor-main']//*[@class='pagination']//a[@rel='next']")
        url = nextLink:length() >= 1 and nextLink:attr("href") or ""
    until not url or url == ""

    -- sort the transactions by booking date descending
    table.sort(transactions, function(one, two)
        return one.bookingDate > two.bookingDate
    end)

    -- group transactions of the same day if configured
    local groupedTransactions = transactions --[=[@as NewTransaction[]]=]
    if account.attributes.GroupTransactions == "true" then
        -- reset the array and build it from scratch with groups
        groupedTransactions = {} --[=[@as NewTransaction[]]=]

        -- the supported grouping types with human-readable label
        -- (every transaction with different booking text is kept ungrouped)
        local types = {
            INVOICING = "invoicing payment",
            ORDER = "order",
            ORDER_UNDO_CHECKOUT = "checkout reversal",
            REFUND = "refund",
            REFUND_REQUEST = "refund request",
            REFUND_REVERSAL = "refund reversal",
            SUBSCRIPTION = "subscription",
            SUB_PAY_REFUND = "subscription payment refund",
            SUB_PAY_REFUND_REVERSAL = "subscription payment refund reversal",
        }

        local currentDate --[[@as timestamp]]
        local currentTransactions = {} --[[@as table<string, table<integer, NewTransaction>>]]

        for _, transaction in ipairs(transactions) do
            local transactionDate = os.date("%F", transaction.bookingDate)

            -- if we have reached another day, group the transactions of the last day
            if transactionDate ~= currentDate then
                pendingBalance = pendingBalance + groupTransactions(currentTransactions, types, groupedTransactions)

                -- reset the temporary variables
                currentDate = transactionDate
                currentTransactions = {}
            end

            if types[transaction.bookingText] then
                -- groupable transaction

                -- initialize table if needed
                if not currentTransactions[transaction.bookingText] then
                    currentTransactions[transaction.bookingText] = {}
                end

                table.insert(currentTransactions[transaction.bookingText], transaction)
            else
                -- ungroupable transaction, add directly
                table.insert(groupedTransactions, transaction)
            end
        end

        -- create final groups for the last day in the transaction list
        pendingBalance = pendingBalance + groupTransactions(currentTransactions, types, groupedTransactions)
    end

    -- add the actual reported balance to the fake payout balance offset
    balance = balance + parseAmount(html:xpath("//*[@class='financial-stats']/*[@class='balance']"):text())

    return {
        balance = balance,
        pendingBalance = pendingBalance,
        transactions = groupedTransactions,
    }
end

---**Fetches PDF statements from the bank**
---
---@param accounts Account[] Accounts to download statements for
---@param knownIdentifiers string[] List of statement identifiers (`statement.identifier`) that have already been downloaded
---@return StatementResults | string # Downloaded statements or error message
function FetchStatements(accounts, knownIdentifiers)
    local startDate = startTime(accounts[1], 0)

    local statements = {} --[=[@as NewStatement[]]=]

    -- collect all invoices from all matching payouts
    local html = HTML(connection:get(url .. "payouts/sent"))
    html:xpath("//*[@id='vendor-main']//pui-tbody//pui-tr"):each(function(_, row)
        local children = row:children()

        local creationDate = parseDate(children:get(2):text())
        if creationDate < startDate then
            -- skip payouts before the start date
            return
        end

        -- find all attachments of this payout
        row:xpath(".//pui-button"):each(function(_, button)
            local href = button:attr("href")

            local invoice = {
                creationDate = creationDate,
                name = href:match("(%d+/[^/]+)$"):gsub("/", "_"),
                identifier = href,
            }

            -- only download the invoice if it wasn't already downloaded
            if not knownIdentifiers[invoice.identifier] then
                invoice.pdf, _, _, invoice.filename = connection:get(invoice.identifier)
                table.insert(statements, invoice)
            end
        end)
    end)

    -- collect all statements of all matching months
    html = HTML(connection:get(url .. "payouts/monthly-statements"))
    html:xpath("//*[@id='vendor-main']//pui-tbody//pui-tr"):each(function(_, row)
        local children = row:children()

        -- the date on the page is the day the month starts, but the
        -- statements are created at the end of the month, so we need to
        -- calculate the last day by adding a month and subtracting a day
        local statementDate = parseDate(children:get(2):text())
        local creationDate = os.time({
            year = os.date("%Y", statementDate) + 0, -- convert to number
            month = os.date("%m", statementDate) + 1,
            day = 1,
        }) - 86400

        if creationDate < startDate then
            -- skip statements of months that ended before the start date
            return
        end

        -- find the URL to the statement PDF in the button
        local href = children:get(3):children():get(1):attr("href")

        local statement = {
            creationDate = creationDate,
            name = os.date("%Y-%m", creationDate) .. " " .. href:match("(%a+)/%d+/%d+$"),
            identifier = href,
        }

        -- only download the statement if it wasn't already downloaded
        if not knownIdentifiers[statement.identifier] then
            statement.pdf, _, _, statement.filename = connection:get(statement.identifier)
            table.insert(statements, statement)
        end
    end)

    return { statements = statements }
end

---**Performs the logout from the backend**
---
---@return string? error Optional error message
function EndSession()
    -- don't perform a logout as the connection is cached
end

-----------------------------------------------------------

---**Checks if the auth session is still active**
---
---@return boolean
function checkSession()
    local html = HTML(connection:get(url --[[@as string]]))
    return html:xpath("//*[@class='sb-header__vendor-name']"):length() >= 1
end

---**Reduces each group of transactions into one transaction**
---
---The grouped transactions are appended to the target table.
---
---@param transactions table<string, table<integer, NewTransaction>> List of transaction groups by booking text
---@param types table<string, string> Mapping of booking texts to human-readable group names
---@param targetTable table<integer, NewTransaction> Table to insert the generated transactions to
---@return number pendingBalance Pending balance of the processed transactions
function groupTransactions(transactions, types, targetTable)
    local pendingBalance = 0

    for bookingText, typeTransactions in pairs(transactions) do
        local groupName = types[bookingText]

        -- append plural s if there are multiple transactions
        if #typeTransactions > 1 then
            groupName = groupName .. "s"
        end

        local amount = tableSum(typeTransactions, "amount")
        local bookingDate = typeTransactions[1].bookingDate
        local currency = typeTransactions[1].currency

        -- mark transactions of the current day as pending
        local booked = os.date("%F", bookingDate) ~= os.date("%F")

        table.insert(targetTable, {
            name = #typeTransactions .. " " .. groupName,
            amount = amount,
            currency = currency,
            bookingDate = bookingDate,
            purpose = "Average: " .. string.format("%.2f", amount / #typeTransactions) .. " " .. currency,
            bookingText = bookingText,
            booked = booked,
        })

        if booked == false then
            pendingBalance = pendingBalance + amount
        end
    end

    return pendingBalance
end

---Returns the string in the current UI language
---
---@param en string English text
---@param de string German text
function localizeText(en, de)
    return MM.language == "de" and de or en
end

---**Performs the login to the Paddle API**
---
---@param credentials { email: string, password: string, code?: string }
---@return LoginChallenge | LoginFailed | string | nil # 2FA challenge or optional error message
function login(credentials)
    -- always request a long session as we will cache it
    credentials.remember = true

    -- first authenticate to the API, which sets a cookie
    local requestBody = JSON():set(credentials):json()
    local responseBody = connection:request(
        "POST",
        "https://api.paddle.com/login",
        requestBody,
        "application/json",
        { Accept = "application/json" }
    )

    -- check for auth errors
    local responseData = JSON(responseBody):dictionary()
    if responseData.error then
        local errorData = responseData.error

        -- invalid credentials
        if errorData.code == "forbidden.invalid_credentials" then
            return LoginFailed
        end

        -- account with enabled 2FA
        if errorData.code == "forbidden.2fa.missing" then
            -- ask the user for the TOTP code
            return {
                title = MM.localizeText("Two-Factor Authentication"),
                challenge = localizeText("Please enter your TOTP code.", "Bitte gebe deinen TOTP-Code ein."),
                label = MM.localizeText("6-digit code"),
            }
        end

        -- other error, return full error
        return string.format(
            MM.localizeText("The web server %s responded with the error message:\n»%s«\nPlease try again later."),
            "api.paddle.com",
            errorData.status .. ": " .. errorData.code
        )
    end

    -- first authentication step (API) has succeeded;
    -- try to request the UI, which redirects a bunch,
    -- does OAuth magic and sets even more cookies;
    -- at the same time this ensures that the login
    -- actually worked
    if checkSession() ~= true then
        -- credentials were correct, but the login still failed for some reason
        return localizeText(
            "Login succeeded, however the Paddle backend could not be fully loaded. Please try again later.",
            "Der Login war erfolgreich, aber das Paddle-Backend konnte nicht vollständig geladen werden. Bitte versuche es später erneut."
        )
    end

    -- no error, success
    return nil
end

---**Extracts a number with optional decimals from a string**
---
---@param amount string
---@return number? string
function parseAmount(amount)
    -- extract the actual amount without currency and
    -- remove the thousand separators for number parsing
    amount = amount:match("([0-9.,]+)"):gsub(",", "")

    return tonumber(amount)
end

---**Extracts an ISO 8601 date (YYYY-MM-DD) from a string
---and converts it into a POSIX timestamp**
---
---@param date string?
---@return timestamp?
function parseDate(date)
    if not date then
        return nil
    end

    local datePattern = "(%d%d%d%d)%-(%d%d)%-(%d%d)"
    local year, month, day = date:match(datePattern)
    return os.time({ year = year, month = month, day = day })
end

---**Determines the refresh start time based on the configuration**
---
---Returns the provided POSIX timestamp,
---but limited to the minimum configured start date
---and at most one year ago.
---
---@param account Account
---@param timestamp timestamp
---@return timestamp
function startTime(account, timestamp)
    local oneYearAgo = os.time() - 60 * 60 * 24 * 365

    return math.max(timestamp, parseDate(account.attributes.StartDate) or 0, oneYearAgo)
end

---**Returns the sum of a specific field of
---all elements of a table**
---
---@param table table<string, any>[]
---@param field string
---@return number
function tableSum(table, field)
    local sum = 0

    for _, value in pairs(table) do
        sum = sum + value[field]
    end

    return sum
end
